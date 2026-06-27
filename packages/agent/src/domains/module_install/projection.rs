use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;

pub(super) fn module_install_request_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleInstallRequestResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
        "identity": projected_identity(payload.get("identity")),
        "validationReport": projected_ref(payload.get("validationReport")),
        "dependencyPolicy": projected_policy(payload.get("dependencyPolicy")),
        "rollback": projected_policy(payload.get("rollback")),
        "installGate": projected_install_gate(payload.get("installGate")),
        "idempotencyFingerprint": payload.pointer("/idempotency/fingerprint")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_install_request")]
    })
}

pub(super) fn inspected_module_install_request(
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
        "installRequest": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "identity": projected_identity(payload.get("identity")),
            "validationReport": projected_ref(payload.get("validationReport")),
            "dependencyPolicy": projected_policy(payload.get("dependencyPolicy")),
            "rollback": projected_policy(payload.get("rollback")),
            "installGate": projected_install_gate(payload.get("installGate")),
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

pub(super) fn module_install_decision_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleInstallDecisionResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
        "request": projected_ref(payload.get("request")),
        "validationReport": projected_ref(payload.get("validationReport")),
        "approval": projected_approval(payload.get("approval")),
        "decision": projected_install_decision(payload.get("decision")),
        "dependencyPolicy": projected_policy(payload.get("dependencyPolicy")),
        "rollback": projected_policy(payload.get("rollback")),
        "idempotencyFingerprint": payload.pointer("/idempotency/fingerprint")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_install_decision")]
    })
}

pub(super) fn inspected_module_install_decision(
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
        "installDecision": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "request": projected_ref(payload.get("request")),
            "validationReport": projected_ref(payload.get("validationReport")),
            "approval": projected_approval(payload.get("approval")),
            "decision": projected_install_decision(payload.get("decision")),
            "dependencyPolicy": projected_policy(payload.get("dependencyPolicy")),
            "rollback": projected_policy(payload.get("rollback")),
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

fn projected_identity(value: Option<&Value>) -> Value {
    let Some(Value::Object(identity)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["title", "summary"] {
        insert_projected_string(identity, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    Value::Object(projected)
}

fn projected_policy(value: Option<&Value>) -> Value {
    let Some(Value::Object(policy)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "status",
        "metadataOnly",
        "restored",
        "packageManagerUsed",
        "rollbackExecuted",
    ] {
        if let Some(value) = policy.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        } else {
            insert_projected_string(policy, &mut projected, key, PROJECTION_ID_BYTES);
        }
    }
    for key in ["refs", "proofRefs"] {
        if let Some(child) = policy.get(key) {
            projected.insert(key.to_owned(), projected_refs(Some(child)));
        }
    }
    Value::Object(projected)
}

fn projected_install_gate(value: Option<&Value>) -> Value {
    let Some(Value::Object(gate)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "metadataOnly",
        "reviewRequired",
        "installPerformed",
        "activationPerformed",
        "executionPerformed",
        "dependencyRestorePerformed",
        "networkAccessPerformed",
    ] {
        if let Some(value) = gate.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    for key in ["state", "networkPolicy"] {
        insert_projected_string(gate, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
}

fn projected_approval(value: Option<&Value>) -> Value {
    let Some(Value::Object(approval)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "allowed",
        "approvalEvidenceOnly",
        "derivedAuthorityRequired",
        "rawAuthorityIdsStored",
    ] {
        if let Some(value) = approval.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    for key in ["outcome", "reason", "riskClass"] {
        insert_projected_string(approval, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in ["requestRef", "decisionRef"] {
        if let Some(child) = approval.get(key) {
            projected.insert(key.to_owned(), projected_ref(Some(child)));
        }
    }
    Value::Object(projected)
}

fn projected_install_decision(value: Option<&Value>) -> Value {
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
    Value::Object(projected)
}

fn projected_side_effect_proof(value: Option<&Value>) -> Value {
    let Some(Value::Object(proof)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "metadataOnly",
        "installPerformed",
        "activationPerformed",
        "executionPerformed",
        "dependencyRestorePerformed",
        "packageManagerUsed",
        "networkAccessPerformed",
        "repoManagedSkillsTouched",
        "physicalWorkspaceDirectoryCreated",
        "rawCommandsStored",
        "rawLogsStored",
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
            projected_text(value, PROJECTION_ID_BYTES),
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
    ] {
        insert_projected_string(item, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    Value::Object(projected)
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    json!({
        "grantRedacted": authority.get("grantRedacted").and_then(Value::as_bool).unwrap_or(true),
        "rawAuthorityIdsStored": authority.get("rawAuthorityIdsStored").and_then(Value::as_bool).unwrap_or(false),
        "derivedRuntimeGrantRequired": authority.get("derivedRuntimeGrantRequired").and_then(Value::as_bool).unwrap_or(true),
        "approvalEvidenceIsAuthority": authority.get("approvalEvidenceIsAuthority").and_then(Value::as_bool).unwrap_or(false),
        "wildcardGrantsAllowed": authority.get("wildcardGrantsAllowed").and_then(Value::as_bool).unwrap_or(false)
    })
}

fn projected_idempotency(value: Option<&Value>) -> Value {
    let Some(Value::Object(idempotency)) = value else {
        return Value::Null;
    };
    json!({
        "fingerprint": idempotency.get("fingerprint").and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "fingerprintAlgorithm": idempotency.get("fingerprintAlgorithm").and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "keyRedacted": idempotency.get("keyRedacted").and_then(Value::as_bool).unwrap_or(true),
        "rawKeyStored": idempotency.get("rawKeyStored").and_then(Value::as_bool).unwrap_or(false)
    })
}

fn projected_scope(resource: &EngineResource, value: Option<&Value>) -> Value {
    let Some(Value::Object(scope)) = value else {
        return json!({"kind": resource.scope.kind(), "value": resource.scope.value()});
    };
    json!({
        "kind": scope.get("kind").and_then(Value::as_str).map(|text| projected_text(text, PROJECTION_ID_BYTES)).unwrap_or(Value::Null),
        "value": scope.get("value").and_then(Value::as_str).map(|text| projected_text(text, PROJECTION_ID_BYTES)).unwrap_or(Value::Null)
    })
}

fn projection_policy() -> Value {
    json!({
        "allowlist": "module_install_metadata_redacted_v1",
        "metadataOnly": true,
        "rawPathsReturned": false,
        "rawEnvReturned": false,
        "rawSecretsReturned": false,
        "rawCommandsReturned": false,
        "rawLogsReturned": false,
        "rawCodeReturned": false,
        "fileContentsReturned": false,
        "grantReferencesReturned": false,
        "authorityReferencesReturned": false,
        "tokenLikeMaterialReturned": false,
        "personalInfoLiteralsReturned": false,
        "debugPayloadReturned": false
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|state| projected_text(state, PROJECTION_ID_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
}

fn projected_string(payload: &Value, key: &str, max_bytes: usize) -> Value {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|text| projected_text(text, max_bytes))
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

fn projected_text(value: &str, max_bytes: usize) -> Value {
    let trimmed = value.trim();
    if trimmed.len() <= max_bytes {
        json!(trimmed)
    } else {
        let mut end = max_bytes;
        while !trimmed.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        json!(format!("{}...", &trimmed[..end]))
    }
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role
    })
}
