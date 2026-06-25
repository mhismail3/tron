use serde_json::{Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

use super::{INSPECT_ARRAY_ITEMS_DEFAULT, STRING_PREVIEW_BYTES};
use crate::domains::worker_lifecycle::{
    CONFORMANCE_KIND, LAUNCH_KIND, PACKAGE_KIND, PROPOSAL_KIND,
};

const METADATA_MAX_DEPTH: usize = 4;
const METADATA_MAX_OBJECT_FIELDS: usize = 32;

pub(super) fn summary_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    kind: &str,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageVersion": payload.get("packageVersion").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
        "state": payload.get("status").cloned().unwrap_or(Value::Null),
        "summary": summary_for_kind(payload, kind),
        "resourceRefs": [version_ref(resource, version, "worker_lifecycle")]
    })
}

pub(super) fn detail_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    kind: &str,
    max_items: usize,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "identity": identity_projection(payload),
        "state": state_projection(payload),
        "provenance": safe_metadata(payload.get("provenance"), max_items),
        "source": source_projection(payload),
        "namespaceClaims": array_preview(payload.get("namespaceClaims"), max_items),
        "expectedFunctions": array_preview(payload.get("expectedFunctions"), max_items),
        "expectedTriggers": array_preview(payload.get("expectedTriggers"), max_items),
        "requestedGrants": requested_grants_projection(payload.get("requestedGrants")),
        "conformance": conformance_projection(payload, max_items),
        "launch": launch_projection(payload),
        "proposal": proposal_projection(payload),
        "installation": installation_projection(payload),
        "traceRefs": safe_metadata(payload.get("traceRefs"), max_items),
        "replayRefs": safe_metadata(payload.get("replayRefs"), max_items),
        "resourceRefs": [version_ref(resource, version, "worker_lifecycle")],
        "redaction": {
            "rawManifest": kind == PACKAGE_KIND || kind == PROPOSAL_KIND,
            "launchToken": true,
            "envValues": true,
            "localPaths": true,
            "endpoint": true,
            "tokenGrantId": true,
            "lifecycleGrant": true
        }
    })
}

fn identity_projection(payload: &Value) -> Value {
    json!({
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageVersion": payload.get("packageVersion").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "launchAttemptResourceId": payload.get("launchAttemptResourceId").cloned().unwrap_or(Value::Null),
        "conformanceReportResourceId": payload.get("conformanceReportResourceId").cloned().unwrap_or(Value::Null)
    })
}

fn state_projection(payload: &Value) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "reason": string_preview(payload.get("reason")),
        "failure": safe_metadata(payload.get("failure"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "ownershipLost": payload.get("ownershipLost").cloned().unwrap_or(Value::Null),
        "stopped": payload.get("stopped").cloned().unwrap_or(Value::Null)
    })
}

fn source_projection(payload: &Value) -> Value {
    let source = payload.get("source").cloned().unwrap_or(Value::Null);
    json!({
        "kind": source.get("kind").cloned().unwrap_or(Value::Null),
        "pathRedacted": source.get("path").is_some(),
        "metadata": source_without_paths(&source),
        "sourceRootRedacted": payload.get("sourceRoot").is_some(),
        "workingDirectoryRedacted": payload.get("workingDirectory").is_some(),
        "launchCommandRedacted": payload.get("launchCommand").is_some() || payload.get("argv").is_some(),
        "envAllowlistCount": payload.get("envAllowlist").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len())),
        "envKeyCount": payload.get("envKeys").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len()))
    })
}

fn source_without_paths(source: &Value) -> Value {
    let mut source = source.clone();
    if let Some(object) = source.as_object_mut() {
        object.retain(|key, _| {
            let lower = key.to_ascii_lowercase();
            !lower.contains("path") && !lower.contains("root") && lower != "workingdirectory"
        });
    }
    source
}

fn requested_grants_projection(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    json!({
        "authorityScopes": array_preview(value.get("authorityScopes"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "resourceKinds": array_preview(value.get("resourceKinds"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "fileRootCount": value.get("fileRoots").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len())),
        "fileRootsRedacted": value.get("fileRoots").is_some(),
        "networkPolicy": value.get("networkPolicy").cloned().unwrap_or(Value::Null),
        "maxRisk": value.get("maxRisk").cloned().unwrap_or(Value::Null),
        "budget": value.get("budget").cloned().unwrap_or(Value::Null)
    })
}

fn conformance_projection(payload: &Value, max_items: usize) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "checks": safe_array_preview(payload.get("checks"), max_items),
        "policy": safe_metadata(payload.get("conformancePolicy"), max_items),
        "catalogRevision": payload.get("catalogRevision").cloned().unwrap_or(Value::Null),
        "launchAttemptResourceId": payload.get("launchAttemptResourceId").cloned().unwrap_or(Value::Null)
    })
}

fn launch_projection(payload: &Value) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "processId": payload.get("processId").cloned().unwrap_or(Value::Null),
        "argvRedacted": payload.get("argv").is_some(),
        "workingDirectoryRedacted": payload.get("workingDirectory").is_some(),
        "endpointRedacted": payload.get("endpoint").is_some(),
        "tokenGrantIdRedacted": payload.get("tokenGrantId").is_some(),
        "envKeyCount": payload.get("envKeys").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len()))
    })
}

fn proposal_projection(payload: &Value) -> Value {
    json!({
        "summary": string_preview(payload.get("summary")),
        "proposedBy": string_preview(payload.get("proposedBy")),
        "manifestRedacted": payload.get("manifest").is_some()
    })
}

fn installation_projection(payload: &Value) -> Value {
    json!({
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "rollbackRef": payload.get("rollbackRef").cloned().unwrap_or(Value::Null),
        "lifecycleGrantRedacted": payload.get("authorityGrantId").is_some()
    })
}

fn summary_for_kind(payload: &Value, kind: &str) -> Value {
    match kind {
        PROPOSAL_KIND => string_preview(payload.get("summary")),
        CONFORMANCE_KIND => json!({
            "status": payload.get("status").cloned().unwrap_or(Value::Null),
            "checkCount": payload.get("checks").and_then(Value::as_array).map_or(0, Vec::len)
        }),
        LAUNCH_KIND => json!({
            "status": payload.get("status").cloned().unwrap_or(Value::Null),
            "processId": payload.get("processId").cloned().unwrap_or(Value::Null)
        }),
        _ => Value::Null,
    }
}

fn array_preview(value: Option<&Value>, max_items: usize) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": max_items});
    };
    json!({
        "items": items.iter().take(max_items).cloned().collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > max_items,
        "maxItems": max_items
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
                    json!({
                        "fieldCount": object.len(),
                        "maxFields": METADATA_MAX_OBJECT_FIELDS
                    }),
                );
            }
            Value::Object(projected)
        }
    }
}

fn safe_string_preview(text: &str) -> Value {
    let lower = text.to_ascii_lowercase();
    if lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || lower.contains("/private/")
        || lower.contains("/users/")
    {
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
        || lower == "argv"
        || lower.contains("command")
        || lower.contains("manifest")
}

fn string_preview(value: Option<&Value>) -> Value {
    let Some(Value::String(text)) = value else {
        return Value::Null;
    };
    let bounded = bounded_utf8(text, STRING_PREVIEW_BYTES);
    json!({
        "text": bounded.text,
        "bytes": text.len(),
        "truncated": bounded.truncated,
        "maxBytes": STRING_PREVIEW_BYTES
    })
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
