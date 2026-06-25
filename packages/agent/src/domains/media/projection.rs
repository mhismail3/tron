use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const TRANSCRIPT_PREVIEW_BYTES: usize = 512;

pub(super) fn media_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "mediaResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "mediaId": projected_string(payload, "mediaId", PROJECTION_ID_BYTES),
        "mediaKind": projected_string(payload, "mediaKind", PROJECTION_ID_BYTES),
        "mimeType": projected_string(payload, "mimeType", PROJECTION_ID_BYTES),
        "sizeBytes": payload.get("sizeBytes").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value)),
        "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
        "summary": projected_string(payload, "summary", PROJECTION_STRING_BYTES),
        "durationMs": payload.get("durationMs").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value)),
        "storage": projected_storage(payload.get("storage")),
        "transcription": projected_transcription(payload.get("transcription")),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "media")]
    })
}

pub(super) fn inspected_media(
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
            "mediaId": projected_string(payload, "mediaId", PROJECTION_ID_BYTES),
            "mediaKind": projected_string(payload, "mediaKind", PROJECTION_ID_BYTES),
            "mimeType": projected_string(payload, "mimeType", PROJECTION_ID_BYTES),
            "sizeBytes": payload.get("sizeBytes").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value)),
            "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
            "summary": projected_string(payload, "summary", PROJECTION_STRING_BYTES),
            "durationMs": payload.get("durationMs").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value)),
            "storage": projected_storage(payload.get("storage")),
            "scope": projected_scope(resource, payload.get("scope")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "archivedAt": projected_string(payload, "archivedAt", PROJECTION_TIMESTAMP_BYTES),
            "retention": projected_object(payload.get("retention"), &["privacyClass", "policy"], &["maxAgeDays"]),
            "transcription": projected_transcription(payload.get("transcription")),
            "refs": projected_refs(payload.get("refs")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": {
            "allowlist": "media_artifact_redacted_v1",
            "rawPayloadReturned": false,
            "rawAudioReturned": false,
            "providerVisibleRawAudio": false,
            "transcriptionReturnedAsPreview": true
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

fn projected_storage(value: Option<&Value>) -> Value {
    let Some(Value::Object(storage)) = value else {
        return Value::Null;
    };
    json!({
        "blobRef": storage
            .get("blobRef")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "contentHash": storage
            .get("contentHash")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "storageClass": storage
            .get("storageClass")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "rawBytesStoredInResource": false,
        "providerVisibleRawAudio": false
    })
}

fn projected_transcription(value: Option<&Value>) -> Value {
    let Some(Value::Object(transcription)) = value else {
        return Value::Null;
    };
    let transcript = transcription.get("text").and_then(Value::as_str);
    json!({
        "state": transcription
            .get("state")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "source": transcription
            .get("source")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "language": transcription
            .get("language")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "model": transcription
            .get("model")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "hasText": transcript.is_some_and(|text| !text.trim().is_empty()),
        "textPreview": transcript
            .map(|text| projected_text(text, TRANSCRIPT_PREVIEW_BYTES))
            .unwrap_or(Value::Null),
        "textBytes": transcript.map_or(Value::Null, |text| json!(text.len())),
        "rawAudioProviderBoundary": "not_sent"
    })
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

fn projected_refs(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Array(items)) => json!({
            "items": items.iter().take(25).map(projected_ref_item).collect::<Vec<_>>(),
            "total": items.len(),
            "truncated": items.len() > 25
        }),
        Some(Value::Object(map)) => {
            let mut projected = Map::new();
            for key in ["source", "evidence", "trace", "replay"] {
                if let Some(child) = map.get(key) {
                    projected.insert(key.to_owned(), projected_refs(Some(child)));
                }
            }
            Value::Object(projected)
        }
        _ => json!({"items": [], "total": 0, "truncated": false}),
    }
}

fn projected_ref_item(value: &Value) -> Value {
    let Value::Object(item) = value else {
        return json!({"redacted": true});
    };
    let mut projected = Map::new();
    for key in [
        "kind",
        "id",
        "resourceId",
        "versionId",
        "contentHash",
        "role",
        "traceId",
        "invocationId",
    ] {
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
        "grantIdRedacted": authority.get("grantId").is_some(),
        "requiredScopes": projected_string_array(authority.get("requiredScopes")),
        "resourceKinds": projected_string_array(authority.get("resourceKinds")),
        "rawAudioProviderAuthorization": authority
            .get("rawAudioProviderAuthorization")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null)
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
            .take(25)
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
    if let Some(text) = source.get(key).and_then(Value::as_str) {
        target.insert(key.to_owned(), projected_text(text, max_bytes));
    }
}

fn projected_text(text: &str, max_bytes: usize) -> Value {
    if text.len() <= max_bytes {
        return Value::String(text.to_owned());
    }
    let mut end = max_bytes;
    while !text.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    Value::String(text[..end].to_owned())
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}
