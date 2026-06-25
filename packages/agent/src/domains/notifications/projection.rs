use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;

pub(super) fn notification_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "notificationResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "notificationId": projected_string(payload, "notificationId", PROJECTION_ID_BYTES),
        "family": projected_string(payload, "family", PROJECTION_ID_BYTES),
        "severity": projected_string(payload, "severity", PROJECTION_ID_BYTES),
        "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
        "body": projected_string(payload, "body", PROJECTION_STRING_BYTES),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "readState": projected_read_state(payload.get("readState")),
        "badge": projected_badge(payload.get("badge")),
        "resourceRefs": [version_ref(resource, version, "notification")]
    })
}

pub(super) fn inspected_notification(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    deliveries: Vec<Value>,
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
            "notificationId": projected_string(payload, "notificationId", PROJECTION_ID_BYTES),
            "family": projected_string(payload, "family", PROJECTION_ID_BYTES),
            "severity": projected_string(payload, "severity", PROJECTION_ID_BYTES),
            "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
            "body": projected_string(payload, "body", PROJECTION_STRING_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "readState": projected_read_state(payload.get("readState")),
            "badge": projected_badge(payload.get("badge")),
            "deliveryPolicy": projected_delivery_policy(payload.get("deliveryPolicy")),
            "retention": projected_object(payload.get("retention"), &["privacyClass", "policy"], &["maxAgeDays", "maxInboxRecords"]),
            "refs": projected_refs(payload.get("refs")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "deliveries": deliveries,
        "projection": {
            "allowlist": "notification_inbox_v1",
            "rawPayloadReturned": false,
            "tokenMaterialReturned": false
        },
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

pub(super) fn delivery_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "notificationDeliveryResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "notificationResourceId": projected_string(payload, "notificationResourceId", PROJECTION_ID_BYTES),
        "deviceRegistrationResourceId": projected_string(payload, "deviceRegistrationResourceId", PROJECTION_ID_BYTES),
        "apnsEnvironment": projected_string(payload, "apnsEnvironment", PROJECTION_ID_BYTES),
        "outcome": projected_object(payload.get("outcome"), &["status", "reason"], &[]),
        "push": projected_push(payload.get("push")),
        "badge": projected_badge(payload.get("badge")),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "notification_delivery")]
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

fn projected_read_state(value: Option<&Value>) -> Value {
    let Some(Value::Object(read)) = value else {
        return Value::Null;
    };
    json!({
        "isRead": read.get("isRead").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "readAt": read
            .get("readAt")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_TIMESTAMP_BYTES))
            .unwrap_or(Value::Null),
        "readByActorId": read.get("readByActorId").is_some().then(|| json!({"redacted": true})).unwrap_or(Value::Null)
    })
}

fn projected_badge(value: Option<&Value>) -> Value {
    let Some(Value::Object(badge)) = value else {
        return Value::Null;
    };
    json!({
        "policy": badge
            .get("policy")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "scope": badge
            .get("scope")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "count": badge.get("count").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value)),
        "includesRead": badge.get("includesRead").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
    })
}

fn projected_delivery_policy(value: Option<&Value>) -> Value {
    let Some(Value::Object(policy)) = value else {
        return Value::Null;
    };
    json!({
        "pushRequested": policy.get("pushRequested").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "liveApnsEnabled": policy.get("liveApnsEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "defaultPushEnabled": policy.get("defaultPushEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "deliveryEvidenceOnly": policy.get("deliveryEvidenceOnly").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
    })
}

fn projected_push(value: Option<&Value>) -> Value {
    let Some(Value::Object(push)) = value else {
        return Value::Null;
    };
    json!({
        "requested": push.get("requested").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "liveApnsAttempted": push.get("liveApnsAttempted").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "liveApnsEnabled": push.get("liveApnsEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "tokenFingerprint": {
            "redacted": true,
            "hashPrefix": push
                .get("tokenHash")
                .and_then(Value::as_str)
                .map(|text| projected_text(&text.chars().take(12).collect::<String>(), 12))
                .unwrap_or(Value::Null)
        }
    })
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    json!({
        "grantIdRedacted": authority.get("grantId").is_some(),
        "requiredScopes": projected_string_array(authority.get("requiredScopes")),
        "resourceKinds": projected_string_array(authority.get("resourceKinds"))
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
