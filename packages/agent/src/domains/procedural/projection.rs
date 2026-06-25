use serde_json::{Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

pub(super) const STRING_PREVIEW_BYTES: usize = 512;
pub(super) const SAFE_SCALAR_STRING_BYTES: usize = 128;
const METADATA_MAX_DEPTH: usize = 4;
const METADATA_MAX_OBJECT_FIELDS: usize = 32;

pub(super) fn summary_projection(
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
        "proceduralKind": payload.get("proceduralKind").cloned().unwrap_or(Value::Null),
        "identity": identity_projection(payload),
        "summary": string_preview(payload.get("summary")),
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "eval": eval_summary(payload.get("eval")),
        "resourceRefs": [version_ref(resource, version, "procedural_record")]
    })
}

pub(super) fn detail_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    max_items: usize,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "proceduralKind": payload.get("proceduralKind").cloned().unwrap_or(Value::Null),
        "identity": identity_projection(payload),
        "summary": string_preview(payload.get("summary")),
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "provenance": safe_metadata(payload.get("provenance"), max_items),
        "eval": safe_metadata(payload.get("eval"), max_items),
        "activation": activation_projection(payload.get("activation")),
        "sourceRefs": safe_array_preview(payload.get("sourceRefs"), max_items),
        "traceRefs": safe_array_preview(payload.get("traceRefs"), max_items),
        "replayRefs": safe_array_preview(payload.get("replayRefs"), max_items),
        "content": content_projection(payload),
        "resourceRefs": [version_ref(resource, version, "procedural_record")],
        "redaction": {
            "rawBody": true,
            "rawManifest": true,
            "rawProcedure": true,
            "secrets": true,
            "env": true,
            "authorityGrantIds": true,
            "unsafePaths": true,
            "activationExecution": true
        }
    })
}

fn identity_projection(payload: &Value) -> Value {
    let identity = payload.get("identity").unwrap_or(&Value::Null);
    json!({
        "id": string_preview(identity.get("id")),
        "name": string_preview(identity.get("name")),
        "version": string_preview(identity.get("version")),
        "namespace": string_preview(identity.get("namespace"))
    })
}

fn eval_summary(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    json!({
        "status": safe_scalar_projection(value.get("status")),
        "profile": string_preview(value.get("profile")),
        "lastRunAt": safe_scalar_projection(value.get("lastRunAt"))
    })
}

fn activation_projection(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return json!({
            "available": false,
            "performed": false,
            "triggerRegistered": false,
            "promptInjected": false,
            "toolExecuted": false,
            "autonomousExecution": false
        });
    };
    json!({
        "available": value.get("available").and_then(Value::as_bool).unwrap_or(false),
        "performed": false,
        "triggerRegistered": false,
        "promptInjected": false,
        "toolExecuted": false,
        "autonomousExecution": false,
        "reason": string_preview(value.get("reason"))
    })
}

fn content_projection(payload: &Value) -> Value {
    json!({
        "bodyRedacted": payload.get("body").is_some() || payload.get("content").is_some(),
        "manifestRedacted": payload.get("manifest").is_some(),
        "implementationRedacted": payload.get("implementation").is_some(),
        "contentRefRedacted": payload.get("contentRef").is_some(),
        "contentHash": content_hash_projection(payload.get("contentHash"))
    })
}

fn safe_array_preview(value: Option<&Value>, max_items: usize) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": max_items});
    };
    json!({
        "items": items
            .iter()
            .take(max_items)
            .map(|item| safe_metadata_value(item, max_items, 0))
            .collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > max_items,
        "maxItems": max_items
    })
}

fn safe_metadata(value: Option<&Value>, max_items: usize) -> Value {
    value
        .map(|value| safe_metadata_value(value, max_items, 0))
        .unwrap_or(Value::Null)
}

fn safe_metadata_value(value: &Value, max_items: usize, depth: usize) -> Value {
    if depth >= METADATA_MAX_DEPTH {
        return json!({"truncated": true, "reason": "maxDepth"});
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        Value::String(text) => safe_string_preview(text),
        Value::Array(items) => json!({
            "items": items
                .iter()
                .take(max_items)
                .map(|item| safe_metadata_value(item, max_items, depth + 1))
                .collect::<Vec<_>>(),
            "total": items.len(),
            "truncated": items.len() > max_items,
            "maxItems": max_items
        }),
        Value::Object(object) => {
            let mut projected = serde_json::Map::new();
            for (key, value) in object.iter().take(METADATA_MAX_OBJECT_FIELDS) {
                if sensitive_metadata_key(key) {
                    projected.insert(key.clone(), json!({"redacted": true}));
                } else {
                    projected.insert(
                        key.clone(),
                        safe_metadata_value(value, max_items, depth + 1),
                    );
                }
            }
            if object.len() > METADATA_MAX_OBJECT_FIELDS {
                projected.insert(
                    "truncated".to_owned(),
                    json!({"fieldCount": object.len(), "maxFields": METADATA_MAX_OBJECT_FIELDS}),
                );
            }
            Value::Object(projected)
        }
    }
}

fn safe_string_preview(text: &str) -> Value {
    if unsafe_projection_text(text) {
        return json!({"redacted": true, "bytes": text.len()});
    }
    let bounded = bounded_utf8(text, STRING_PREVIEW_BYTES);
    json!({
        "text": bounded.text,
        "bytes": text.len(),
        "truncated": bounded.truncated,
        "maxBytes": STRING_PREVIEW_BYTES
    })
}

fn sensitive_metadata_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || lower.contains("env")
        || lower.contains("path")
        || lower.contains("root")
        || lower.contains("endpoint")
        || lower.contains("manifest")
        || lower.contains("body")
        || lower.contains("content")
        || lower.contains("implementation")
        || lower.contains("failure")
        || contains_grant_identifier_key(&lower)
}

fn contains_grant_identifier_key(lower: &str) -> bool {
    let compact = compact_ascii_alphanumeric(lower);
    compact == "grant"
        || compact.contains("grantid")
        || compact.contains("grantidentifier")
        || compact.contains("grantreference")
        || compact.contains("grantref")
        || compact.contains("authoritygrant")
}

fn contains_grant_identifier_text(lower: &str) -> bool {
    let compact = compact_ascii_alphanumeric(lower);
    compact.contains("authoritygrantid")
        || compact.contains("grantid")
        || compact.contains("grantidentifier")
        || lower.contains("grant-")
        || lower.contains("grant_")
        || lower.contains("grant:")
        || lower.contains("grant/")
}

fn compact_ascii_alphanumeric(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .collect()
}

fn string_preview(value: Option<&Value>) -> Value {
    let Some(Value::String(text)) = value else {
        return Value::Null;
    };
    safe_string_preview(text)
}

fn safe_scalar_projection(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    let Some(text) = value.as_str() else {
        return Value::Null;
    };
    if is_safe_projection_scalar(text) {
        Value::String(text.to_owned())
    } else {
        json!({"redacted": true, "bytes": text.len()})
    }
}

fn content_hash_projection(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    let Some(text) = value.as_str() else {
        return Value::Null;
    };
    if is_safe_content_hash(text) {
        Value::String(text.to_owned())
    } else {
        json!({"redacted": true, "bytes": text.len()})
    }
}

pub(super) fn is_safe_projection_scalar(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= SAFE_SCALAR_STRING_BYTES
        && text.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.' | b'+' | b'Z')
        })
        && !unsafe_projection_text(text)
}

pub(super) fn is_safe_content_hash(text: &str) -> bool {
    let Some(hex) = text.strip_prefix("sha256:") else {
        return false;
    };
    hex.len() == 64 && hex.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn unsafe_projection_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || contains_grant_identifier_text(&lower)
        || lower.contains("/private/")
        || lower.contains("/users/")
        || lower.contains("~/")
        || lower.contains("~/.")
        || lower.starts_with('/')
        || lower.contains(":\\")
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

struct BoundedText {
    text: String,
    truncated: bool,
}

fn bounded_utf8(value: &str, max_bytes: usize) -> BoundedText {
    if value.len() <= max_bytes {
        return BoundedText {
            text: value.to_owned(),
            truncated: false,
        };
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    BoundedText {
        text: value[..end].to_owned(),
        truncated: true,
    }
}
