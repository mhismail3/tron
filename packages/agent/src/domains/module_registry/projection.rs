use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

use super::manifest::{INSPECT_ITEMS_MAX, unsafe_text};

const STRING_PREVIEW_BYTES: usize = 160;
const METADATA_MAX_DEPTH: usize = 5;
const METADATA_MAX_OBJECT_FIELDS: usize = 24;

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
        "identity": identity_projection(payload),
        "capabilityCount": array_len(payload.get("capabilityDeclarations")),
        "resourceDeclarationCount": array_len(payload.get("resourceDeclarations")),
        "authorityNeedCount": array_len(payload.get("authorityNeeds")),
        "settingsDeclarationCount": array_len(payload.get("settingsDeclarations")),
        "dependencyIntentCount": array_len(payload.get("dependencyIntents")),
        "validation": validation_summary(payload),
        "provenance": provenance_summary(payload),
        "sideEffects": side_effect_proof(),
        "resourceRefs": [version_ref(resource, version, "module_manifest")]
    })
}

pub(super) fn detail_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    max_items: usize,
) -> Value {
    let max_items = max_items.min(INSPECT_ITEMS_MAX);
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "resourceLifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "identity": identity_projection(payload),
        "capabilityDeclarations": safe_array_preview(payload.get("capabilityDeclarations"), max_items),
        "resourceDeclarations": safe_array_preview(payload.get("resourceDeclarations"), max_items),
        "authorityNeeds": safe_array_preview(payload.get("authorityNeeds"), max_items),
        "settingsDeclarations": safe_array_preview(payload.get("settingsDeclarations"), max_items),
        "dependencyIntents": safe_array_preview(payload.get("dependencyIntents"), max_items),
        "validation": safe_metadata(payload.get("validation"), max_items),
        "provenance": safe_metadata(payload.get("provenance"), max_items),
        "manifestLifecycle": safe_metadata(payload.get("lifecycle"), max_items),
        "redactionProof": safe_metadata(payload.get("redactionProof"), max_items),
        "sideEffects": side_effect_proof(),
        "resourceRefs": [version_ref(resource, version, "module_manifest")],
        "redaction": {
            "rawManifest": true,
            "localPaths": true,
            "environmentValues": true,
            "commands": true,
            "sensitiveValues": true,
            "grantIdentifiers": true,
            "authorityIdentifiers": true,
            "tokenLikeMaterial": true,
            "personalInfoLiterals": true
        }
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "writes": false,
        "install": false,
        "activation": false,
        "execution": false,
        "dependencyResolution": false,
        "network": {"performed": false, "requiredPolicy": "none"}
    })
}

fn identity_projection(payload: &Value) -> Value {
    let identity = payload.get("identity").unwrap_or(&Value::Null);
    json!({
        "moduleId": string_preview(identity.get("moduleId")),
        "name": string_preview(identity.get("name")),
        "kind": string_preview(identity.get("kind")),
        "owner": string_preview(identity.get("owner")),
        "summary": string_preview(identity.get("summary")),
        "version": string_preview(identity.get("version"))
    })
}

fn validation_summary(payload: &Value) -> Value {
    let validation = payload.get("validation").unwrap_or(&Value::Null);
    json!({
        "status": string_preview(validation.get("status")),
        "checkCount": array_len(validation.get("checks")),
        "evidenceRefCount": array_len(validation.get("evidenceRefs"))
    })
}

fn provenance_summary(payload: &Value) -> Value {
    let provenance = payload.get("provenance").unwrap_or(&Value::Null);
    json!({
        "source": string_preview(provenance.get("source")),
        "sourceRefCount": array_len(provenance.get("sourceRefs"))
    })
}

fn array_len(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map_or(0, Vec::len)
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
        Value::String(text) => safe_string_value(text),
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
            let mut projected = Map::new();
            for (key, value) in object.iter().take(METADATA_MAX_OBJECT_FIELDS) {
                if sensitive_projection_key(key) {
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

fn string_preview(value: Option<&Value>) -> Value {
    let Some(Value::String(text)) = value else {
        return Value::Null;
    };
    safe_string_value(text)
}

fn safe_string_value(text: &str) -> Value {
    if unsafe_text(text) {
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

fn sensitive_projection_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "secret"
            | "token"
            | "password"
            | "credential"
            | "credentials"
            | "env"
            | "environment"
            | "path"
            | "command"
            | "cmd"
            | "argv"
            | "grantid"
            | "authorityid"
    ) || lower.contains("grant_id")
        || lower.contains("authority_id")
        || lower.contains("api_key")
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

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}
