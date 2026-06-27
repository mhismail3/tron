use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;

pub(super) fn module_proposal_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleProposalResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "proposalId": projected_string(payload, "proposalId", PROJECTION_ID_BYTES),
        "identity": projected_identity(payload.get("identity")),
        "intendedModuleRefs": projected_refs(payload.get("intendedModuleRefs")),
        "sourceRefCount": ref_count(payload.pointer("/refs/source")),
        "docRefCount": ref_count(payload.pointer("/refs/docs")),
        "testRefCount": ref_count(payload.pointer("/refs/tests")),
        "validation": projected_validation(payload.get("validation")),
        "lifecycle": projected_lifecycle(payload.get("lifecycle")),
        "safetyProof": projected_safety_proof(payload.get("safetyProof")),
        "idempotencyFingerprint": payload
            .pointer("/idempotency/fingerprint")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_proposal")]
    })
}

pub(super) fn inspected_module_proposal(
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
        "proposal": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "proposalId": projected_string(payload, "proposalId", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "identity": projected_identity(payload.get("identity")),
            "intendedModuleRefs": projected_refs(payload.get("intendedModuleRefs")),
            "refs": projected_support_refs(payload.get("refs")),
            "validation": projected_validation(payload.get("validation")),
            "lifecycle": projected_lifecycle(payload.get("lifecycle")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "idempotency": projected_idempotency(payload.get("idempotency")),
            "safetyProof": projected_safety_proof(payload.get("safetyProof")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": {
            "allowlist": "module_proposal_metadata_redacted_v1",
            "metadataOnly": true,
            "rawProposalBodyReturned": false,
            "rawPromptReturned": false,
            "commandsReturned": false,
            "fileContentsReturned": false,
            "absolutePathsReturned": false,
            "grantReferencesReturned": false,
            "authorityReferencesReturned": false,
            "tokenLikeMaterialReturned": false,
            "personalInfoLiteralsReturned": false
        },
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

fn projected_validation(value: Option<&Value>) -> Value {
    let Some(Value::Object(validation)) = value else {
        return Value::Null;
    };
    json!({
        "status": validation
            .get("status")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "placeholder": validation
            .get("placeholder")
            .and_then(Value::as_bool)
            .map_or(Value::Null, |value| json!(value)),
        "checks": projected_refs(validation.get("checks"))
    })
}

fn projected_lifecycle(value: Option<&Value>) -> Value {
    let Some(Value::Object(lifecycle)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "state",
        "networkPolicy",
        "install",
        "execution",
        "activation",
        "dependencyRestore",
    ] {
        insert_projected_string(lifecycle, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
}

fn projected_safety_proof(value: Option<&Value>) -> Value {
    let Some(Value::Object(proof)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "noInstall",
        "noExecution",
        "dependencyRestorePerformed",
        "packageManagerUsed",
        "networkAccessPerformed",
        "repoManagedSkillsTouched",
        "rawProposalBodyStored",
        "rawPromptStored",
        "commandsStored",
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

fn projected_support_refs(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Object(map)) => {
            let mut projected = Map::new();
            for key in ["source", "docs", "tests", "trace", "replay"] {
                if let Some(child) = map.get(key) {
                    projected.insert(key.to_owned(), projected_refs(Some(child)));
                }
            }
            Value::Object(projected)
        }
        _ => json!({
            "source": {"items": [], "total": 0, "truncated": false},
            "docs": {"items": [], "total": 0, "truncated": false},
            "tests": {"items": [], "total": 0, "truncated": false},
            "trace": {"items": [], "total": 0, "truncated": false},
            "replay": {"items": [], "total": 0, "truncated": false}
        }),
    }
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

fn projected_ref_item(value: &Value) -> Value {
    let Value::Object(item) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["kind", "id", "resourceId", "role", "versionId"] {
        insert_projected_string(item, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if projected.is_empty() && !item.is_empty() {
        projected.insert("redacted".to_owned(), json!(true));
    }
    Value::Object(projected)
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    json!({
        "grantRedacted": true,
        "requiredScopes": projected_string_array(authority.get("requiredScopes")),
        "resourceKinds": projected_string_array(authority.get("resourceKinds")),
        "wildcardGrantsAllowed": authority.get("wildcardGrantsAllowed").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "rawAuthorityIdsStored": authority.get("rawAuthorityIdsStored").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
    })
}

fn projected_idempotency(value: Option<&Value>) -> Value {
    let Some(Value::Object(idempotency)) = value else {
        return Value::Null;
    };
    json!({
        "fingerprint": idempotency
            .get("fingerprint")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "fingerprintAlgorithm": idempotency
            .get("fingerprintAlgorithm")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "keyRedacted": idempotency.get("keyRedacted").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "rawKeyStored": idempotency.get("rawKeyStored").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|state| projected_text(state, PROJECTION_ID_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
}

fn projected_scope(resource: &EngineResource, value: Option<&Value>) -> Value {
    let Some(Value::Object(scope)) = value else {
        return json!({"kind": resource.scope.kind(), "value": resource.scope.value()});
    };
    json!({
        "kind": scope
            .get("kind")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "value": scope
            .get("value")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_string(payload: &Value, field: &str, max_bytes: usize) -> Value {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(|text| projected_text(text, max_bytes))
        .unwrap_or(Value::Null)
}

fn projected_string_array(value: Option<&Value>) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!([]);
    };
    Value::Array(
        items
            .iter()
            .filter_map(Value::as_str)
            .take(MAX_PROJECTED_REFS)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .collect(),
    )
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

fn ref_count(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map_or(0, Vec::len)
}

fn projected_text(text: &str, max_bytes: usize) -> Value {
    json!(truncate_utf8(text, max_bytes))
}

fn truncate_utf8(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let mut end = max_bytes.min(text.len());
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role
    })
}
