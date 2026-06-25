use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;

pub(super) fn device_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "deviceRegistrationResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "deviceId": projected_string(payload, "deviceId", PROJECTION_STRING_BYTES),
        "platform": projected_string(payload, "platform", PROJECTION_STRING_BYTES),
        "apns": projected_apns(payload.get("apns")),
        "notificationPolicy": projected_notification_policy(payload.get("notificationPolicy")),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "device_registration")]
    })
}

pub(super) fn inspected_device(
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
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_STRING_BYTES),
            "state": projected_state(resource, payload),
            "deviceId": projected_string(payload, "deviceId", PROJECTION_STRING_BYTES),
            "platform": projected_string(payload, "platform", PROJECTION_STRING_BYTES),
            "label": projected_string(payload, "label", PROJECTION_STRING_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "apns": projected_apns(payload.get("apns")),
            "notificationPolicy": projected_notification_policy(payload.get("notificationPolicy")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "unregistered": projected_unregistered(payload.get("unregistered")),
            "retention": projected_object_strings(payload.get("retention"), &["privacyClass", "tokenCustody"], &["maxAgeDays", "maxInboxRecords"]),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": {
            "allowlist": "device_registration_v1",
            "rawPayloadReturned": false,
            "apnsTokenReturned": false,
            "fullTokenHashReturned": false
        },
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|state| projected_text(state, PROJECTION_STRING_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_STRING_BYTES))
}

fn projected_string(payload: &Value, field: &str, max_bytes: usize) -> Value {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(|text| projected_text(text, max_bytes))
        .unwrap_or(Value::Null)
}

fn projected_apns(value: Option<&Value>) -> Value {
    let Some(Value::Object(apns)) = value else {
        return Value::Null;
    };
    json!({
        "environment": apns
            .get("environment")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null),
        "tokenFingerprint": {
            "redacted": true,
            "hashPrefix": apns
                .get("tokenHash")
                .and_then(Value::as_str)
                .map(|text| projected_text(&text.chars().take(12).collect::<String>(), 12))
                .unwrap_or(Value::Null),
            "preview": apns
                .get("tokenPreview")
                .and_then(Value::as_str)
                .map(|text| projected_text(text, 32))
                .unwrap_or(Value::Null)
        },
        "tokenStorage": apns
            .get("tokenStorage")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null),
        "liveApnsEnabled": apns.get("liveApnsEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "registeredAt": apns
            .get("registeredAt")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_TIMESTAMP_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_notification_policy(value: Option<&Value>) -> Value {
    let Some(Value::Object(policy)) = value else {
        return Value::Null;
    };
    json!({
        "optIn": policy.get("optIn").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "pushEnabled": policy.get("pushEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "defaultPushEnabled": policy.get("defaultPushEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "liveApnsEnabled": policy.get("liveApnsEnabled").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "eventFamilies": projected_string_array(policy.get("eventFamilies")),
        "badgePolicy": projected_object_strings(policy.get("badgePolicy"), &["mode", "scope"], &[])
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
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null),
        "value": scope
            .get("value")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_unregistered(value: Option<&Value>) -> Value {
    let Some(Value::Object(record)) = value else {
        return Value::Null;
    };
    projected_object_strings(
        Some(&Value::Object(record.clone())),
        &["at", "actorId", "reason"],
        &[],
    )
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    json!({
        "grantIdRedacted": authority.get("grantId").is_some(),
        "requiredScopes": projected_string_array(authority.get("requiredScopes")),
        "resourceKind": authority
            .get("resourceKind")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_refs(value: Option<&Value>) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false});
    };
    json!({
        "items": items.iter().take(25).map(projected_ref_item).collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > 25
    })
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

fn projected_object_strings(
    value: Option<&Value>,
    string_keys: &[&str],
    number_keys: &[&str],
) -> Value {
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
