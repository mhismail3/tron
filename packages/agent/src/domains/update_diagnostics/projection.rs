use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 16;

pub(super) fn update_diagnostic_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "updateDiagnosticResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "diagnosticId": projected_string(payload, "diagnosticId", PROJECTION_ID_BYTES),
        "checkKind": projected_string(payload, "checkKind", PROJECTION_ID_BYTES),
        "release": projected_release(payload.get("release")),
        "metadata": projected_metadata(payload.get("metadata")),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "update_diagnostic")]
    })
}

pub(super) fn inspected_update_diagnostic(
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
        "payload": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "diagnosticId": projected_string(payload, "diagnosticId", PROJECTION_ID_BYTES),
            "checkKind": projected_string(payload, "checkKind", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "release": projected_release(payload.get("release")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "retention": projected_object(payload.get("retention"), &["privacyClass", "policy"], &["maxAgeDays"]),
            "metadata": projected_metadata(payload.get("metadata")),
            "refs": projected_support_refs(payload.get("refs")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": {
            "allowlist": "update_diagnostic_record_redacted_v1",
            "rawPayloadReturned": false,
            "rawProductionEndpointReturned": false,
            "packageBytesReturned": false,
            "installOrRestartReturned": false
        },
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|state| projected_text(state, PROJECTION_ID_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
}

fn projected_string(payload: &Value, field: &str, max_bytes: usize) -> Value {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(|text| projected_text(text, max_bytes))
        .unwrap_or(Value::Null)
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

fn projected_release(value: Option<&Value>) -> Value {
    let Some(Value::Object(release)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "channel",
        "version",
        "build",
        "diagnosticStatus",
        "signatureStatus",
    ] {
        insert_projected_string(release, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
}

fn projected_metadata(value: Option<&Value>) -> Value {
    let Some(Value::Object(metadata)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["diagnosticLabel", "diagnosticSummary", "provenanceSummary"] {
        insert_projected_string(metadata, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in [
        "signedReleaseMetadataOnly",
        "liveNetworkCheckPerformed",
        "productionEndpointStored",
        "packageBytesStored",
        "installerExecutionAllowed",
        "restartExecutionAllowed",
        "deployAutomationStored",
        "nativeUiRequired",
    ] {
        if let Some(value) = metadata.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    Value::Object(projected)
}

fn projected_support_refs(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Object(map)) => {
            let mut projected = Map::new();
            for key in ["source", "evidence", "provenance", "signature"] {
                if let Some(child) = map.get(key) {
                    projected.insert(key.to_owned(), projected_refs(Some(child)));
                }
            }
            Value::Object(projected)
        }
        _ => json!({
            "source": {"items": [], "total": 0, "truncated": false},
            "evidence": {"items": [], "total": 0, "truncated": false},
            "provenance": {"items": [], "total": 0, "truncated": false},
            "signature": {"items": [], "total": 0, "truncated": false}
        }),
    }
}

fn projected_refs(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Array(items)) => json!({
            "items": items.iter().take(MAX_PROJECTED_REFS).map(|item| projected_ref_item(Some(item))).collect::<Vec<_>>(),
            "total": items.len(),
            "truncated": items.len() > MAX_PROJECTED_REFS
        }),
        _ => json!({"items": [], "total": 0, "truncated": false}),
    }
}

fn projected_ref_item(value: Option<&Value>) -> Value {
    let Some(Value::Object(item)) = value else {
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
        "grantRedacted": authority.get("grantId").is_some(),
        "requiredScopes": projected_string_array(authority.get("requiredScopes")),
        "resourceKinds": projected_string_array(authority.get("resourceKinds")),
        "networkPolicy": authority.get("networkPolicy").and_then(Value::as_str).map(|value| projected_text(value, PROJECTION_ID_BYTES)).unwrap_or(Value::Null)
    })
}

fn projected_object(value: Option<&Value>, string_keys: &[&str], number_keys: &[&str]) -> Value {
    let Some(Value::Object(object)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in string_keys {
        insert_projected_string(object, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in number_keys {
        if let Some(value) = object.get(*key).and_then(Value::as_u64) {
            projected.insert((*key).to_owned(), json!(value));
        }
    }
    Value::Object(projected)
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

fn projected_text(text: &str, max_bytes: usize) -> Value {
    let value = truncate_utf8(text, max_bytes).to_owned();
    json!(value)
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
