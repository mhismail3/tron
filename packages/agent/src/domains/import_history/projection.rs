use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 16;

pub(super) fn import_history_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "importHistoryResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "recordId": projected_string(payload, "recordId", PROJECTION_ID_BYTES),
        "graphKind": projected_string(payload, "graphKind", PROJECTION_ID_BYTES),
        "subject": projected_subject(payload.get("subjectRef")),
        "lineage": projected_lineage_counts(payload),
        "metadata": projected_metadata(payload.get("metadata")),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "import_history")]
    })
}

pub(super) fn inspected_import_history(
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
            "recordId": projected_string(payload, "recordId", PROJECTION_ID_BYTES),
            "graphKind": projected_string(payload, "graphKind", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "subjectRef": projected_ref_item(payload.get("subjectRef")),
            "parentRefs": projected_refs(payload.get("parentRefs")),
            "childRefs": projected_refs(payload.get("childRefs")),
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
            "allowlist": "import_history_record_redacted_v1",
            "rawPayloadReturned": false,
            "rawRepositoryTreeReturned": false,
            "genericGraphOnly": true
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

fn projected_subject(value: Option<&Value>) -> Value {
    projected_ref_item(value)
}

fn projected_lineage_counts(payload: &Value) -> Value {
    json!({
        "parents": projected_count(payload.get("parentRefs")),
        "children": projected_count(payload.get("childRefs"))
    })
}

fn projected_count(value: Option<&Value>) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"total": 0, "truncated": false});
    };
    json!({"total": items.len(), "truncated": items.len() > MAX_PROJECTED_REFS})
}

fn projected_metadata(value: Option<&Value>) -> Value {
    let Some(Value::Object(metadata)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "lineageLabel",
        "lineageSummary",
        "renderHint",
        "importSourceKind",
    ] {
        insert_projected_string(metadata, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in ["nativeTreeRequired", "genericGraphOnly"] {
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
            for key in ["source", "evidence"] {
                if let Some(child) = map.get(key) {
                    projected.insert(key.to_owned(), projected_refs(Some(child)));
                }
            }
            Value::Object(projected)
        }
        _ => json!({
            "source": {"items": [], "total": 0, "truncated": false},
            "evidence": {"items": [], "total": 0, "truncated": false}
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
        "genericGraphOnly": authority.get("genericGraphOnly").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
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
    let value = if text.len() > max_bytes {
        text[..max_bytes].to_owned()
    } else {
        text.to_owned()
    };
    json!(value)
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role
    })
}
