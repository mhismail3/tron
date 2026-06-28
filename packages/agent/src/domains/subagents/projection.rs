use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

use super::validation::{MAX_REF_ITEMS, MAX_SUMMARY_BYTES, validate_state};

pub(super) const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;

pub(super) fn task_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "taskId": projected_string_field(payload, "taskId", PROJECTION_ID_BYTES),
        "state": projected_state(resource, payload),
        "objectiveSummary": projected_string_field(payload, "objectiveSummary", MAX_SUMMARY_BYTES),
        "promptSummary": projected_string_field(payload, "promptSummary", MAX_SUMMARY_BYTES),
        "parent": projected_parent(payload.get("parent")),
        "createdAt": projected_string_field(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string_field(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "refs": projected_refs(payload.get("refs")),
        "resourceRefs": [version_ref(resource, version, "subagent_task")]
    })
}

pub(super) fn inspected_task(
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
        "payload": projected_task_payload(resource, payload),
        "resourceRefs": [version_ref(resource, version, "inspected")],
        "projection": {
            "allowlist": "subagent_task_lifecycle_v1",
            "rawPayloadReturned": false,
            "maxSummaryBytes": MAX_SUMMARY_BYTES,
            "maxRefItems": MAX_REF_ITEMS,
            "stringPreviewBytes": PROJECTION_STRING_BYTES
        }
    })
}

fn projected_task_payload(resource: &EngineResource, payload: &Value) -> Value {
    json!({
        "schemaVersion": projected_string_field(payload, "schemaVersion", PROJECTION_ID_BYTES),
        "state": projected_state(resource, payload),
        "taskId": projected_string_field(payload, "taskId", PROJECTION_ID_BYTES),
        "parent": projected_parent(payload.get("parent")),
        "scope": projected_scope(resource, payload.get("scope")),
        "objectiveSummary": projected_string_field(payload, "objectiveSummary", MAX_SUMMARY_BYTES),
        "promptSummary": projected_string_field(payload, "promptSummary", MAX_SUMMARY_BYTES),
        "createdAt": projected_string_field(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string_field(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "refs": projected_refs(payload.get("refs")),
        "result": projected_placeholder(payload.get("result")),
        "error": projected_placeholder(payload.get("error")),
        "delegation": projected_delegation(payload.get("delegation")),
        "authority": projected_authority(payload.get("authority")),
        "execution": projected_execution(payload.get("execution")),
        "activation": projected_activation(payload.get("activation")),
        "network": projected_network(payload.get("network")),
        "redaction": projected_redaction(payload.get("redaction")),
        "limits": projected_limits(payload.get("limits")),
        "idempotency": projected_idempotency(payload.get("idempotency")),
        "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| validate_state(state).is_ok())
        .map(|state| projected_text(state, PROJECTION_ID_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
}

fn projected_string_field(payload: &Value, field: &str, max_bytes: usize) -> Value {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(|text| projected_text(text, max_bytes))
        .unwrap_or(Value::Null)
}

fn projected_parent(value: Option<&Value>) -> Value {
    let Some(Value::Object(parent)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "sessionId",
        "workspaceId",
        "traceId",
        "parentInvocationId",
        "actorId",
        "actorKind",
    ] {
        insert_projected_string(parent, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
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
    let refs = value.unwrap_or(&Value::Null);
    json!({
        "trace": projected_ref_array(refs.get("trace")),
        "replay": projected_ref_array(refs.get("replay")),
        "evidence": projected_ref_array(refs.get("evidence")),
        "outputs": projected_ref_array(refs.get("outputs")),
        "handoff": projected_ref_array(refs.get("handoff"))
    })
}

fn projected_ref_array(value: Option<&Value>) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": MAX_REF_ITEMS});
    };
    json!({
        "items": items
            .iter()
            .take(MAX_REF_ITEMS)
            .map(projected_ref_item)
            .collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > MAX_REF_ITEMS,
        "maxItems": MAX_REF_ITEMS
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

fn projected_placeholder(value: Option<&Value>) -> Value {
    match value {
        None | Some(Value::Null) => Value::Null,
        Some(Value::Object(placeholder)) => {
            let mut projected = Map::new();
            for key in ["kind", "status", "summary", "message", "code"] {
                insert_projected_string(placeholder, &mut projected, key, PROJECTION_STRING_BYTES);
            }
            if placeholder.get("resourceRefs").is_some() {
                projected.insert(
                    "resourceRefs".to_owned(),
                    projected_ref_array(placeholder.get("resourceRefs")),
                );
            }
            if placeholder.get("evidenceRefs").is_some() {
                projected.insert(
                    "evidenceRefs".to_owned(),
                    projected_ref_array(placeholder.get("evidenceRefs")),
                );
            }
            if placeholder.get("outputRefs").is_some() {
                projected.insert(
                    "outputRefs".to_owned(),
                    projected_ref_array(placeholder.get("outputRefs")),
                );
            }
            if placeholder.get("mergeProposal").is_some() {
                projected.insert(
                    "mergeProposal".to_owned(),
                    projected_merge_proposal(placeholder.get("mergeProposal")),
                );
            }
            if placeholder.keys().any(|key| {
                !matches!(
                    key.as_str(),
                    "kind"
                        | "status"
                        | "summary"
                        | "message"
                        | "code"
                        | "resourceRefs"
                        | "evidenceRefs"
                        | "outputRefs"
                        | "mergeProposal"
                )
            }) {
                projected.insert("redacted".to_owned(), json!(true));
            }
            Value::Object(projected)
        }
        Some(_) => json!({"redacted": true}),
    }
}

fn projected_delegation(value: Option<&Value>) -> Value {
    let Some(Value::Object(delegation)) = value else {
        return Value::Null;
    };
    json!({
        "workerKind": delegation
            .get("workerKind")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "modulePackId": delegation
            .get("modulePackId")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "moduleRuntimeRef": projected_ref_item(delegation.get("moduleRuntimeRef").unwrap_or(&Value::Null)),
        "jobRef": projected_ref_item(delegation.get("jobRef").unwrap_or(&Value::Null)),
        "programExecutionRef": projected_ref_item(delegation.get("programExecutionRef").unwrap_or(&Value::Null)),
        "binding": projected_object_strings(
            delegation.get("binding"),
            &["validatedBy"],
            &["runtimeJobBindingRequired"]
        ),
        "providerSafety": projected_object_strings(
            delegation.get("providerSafety"),
            &[],
            &[
                "rawPromptStored",
                "rawResultStored",
                "rawCommandReturned",
                "rawOutputReturned",
                "toolLogsStored",
                "localPathsStored"
            ]
        )
    })
}

fn projected_merge_proposal(value: Option<&Value>) -> Value {
    let Some(Value::Object(proposal)) = value else {
        return Value::Null;
    };
    json!({
        "kind": proposal
            .get("kind")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "status": proposal
            .get("status")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "reviewRequired": proposal.get("reviewRequired").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "parentConversationMutated": proposal.get("parentConversationMutated").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "moduleRuntimeRef": projected_ref_item(proposal.get("moduleRuntimeRef").unwrap_or(&Value::Null)),
        "jobRef": projected_ref_item(proposal.get("jobRef").unwrap_or(&Value::Null)),
        "programExecutionRef": projected_ref_item(proposal.get("programExecutionRef").unwrap_or(&Value::Null)),
        "rawResultReturned": proposal.get("rawResultReturned").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "rawOutputReturned": proposal.get("rawOutputReturned").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value))
    })
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
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_execution(value: Option<&Value>) -> Value {
    let Some(Value::Object(execution)) = value else {
        return Value::Null;
    };
    json!({
        "schemaVersion": execution
            .get("schemaVersion")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "modelPolicy": execution
            .get("modelPolicy")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .unwrap_or(Value::Null),
        "profilePolicy": projected_object_strings(
            execution.get("profilePolicy"),
            &["mode"],
            &["settingsMigrationRequired"]
        ),
        "concurrency": projected_object_numbers_and_strings(
            execution.get("concurrency"),
            &["maxRunningPerScope"],
            &["scopeKind"]
        ),
        "worker": projected_object_strings(
            execution.get("worker"),
            &["kind"],
            &["started"]
        ),
        "job": projected_object_strings(
            execution.get("job"),
            &["backing"],
            &["jobStarted", "processStarted"]
        ),
        "cancellation": projected_object_strings(
            execution.get("cancellation"),
            &["reason"],
            &[
                "supported",
                "requested",
                "workerCancelRequested",
                "jobCancelRequested",
                "processSignalSent"
            ]
        ),
        "sideEffects": projected_object_strings(
            execution.get("sideEffects"),
            &[],
            &[
                "toolExecution",
                "network",
                "browser",
                "packageLaunch",
                "catalogRegistration",
                "trustPromotion"
            ]
        )
    })
}

fn projected_activation(value: Option<&Value>) -> Value {
    let Some(Value::Object(activation)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "performed",
        "subagentStarted",
        "workerStarted",
        "jobStarted",
        "processStarted",
        "catalogRegistration",
        "toolExecution",
        "resultMerged",
    ] {
        if let Some(flag) = activation.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(flag));
        }
    }
    Value::Object(projected)
}

fn projected_object_strings(
    value: Option<&Value>,
    string_keys: &[&str],
    bool_keys: &[&str],
) -> Value {
    let Some(Value::Object(map)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in string_keys {
        insert_projected_string(map, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in bool_keys {
        if let Some(flag) = map.get(*key).and_then(Value::as_bool) {
            projected.insert((*key).to_owned(), json!(flag));
        }
    }
    Value::Object(projected)
}

fn projected_object_numbers_and_strings(
    value: Option<&Value>,
    number_keys: &[&str],
    string_keys: &[&str],
) -> Value {
    let Some(Value::Object(map)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in number_keys {
        if let Some(number) = map.get(*key).and_then(Value::as_u64) {
            projected.insert((*key).to_owned(), json!(number));
        }
    }
    for key in string_keys {
        insert_projected_string(map, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    Value::Object(projected)
}

fn projected_network(value: Option<&Value>) -> Value {
    let Some(Value::Object(network)) = value else {
        return Value::Null;
    };
    json!({
        "performed": network.get("performed").and_then(Value::as_bool).map_or(Value::Null, |value| json!(value)),
        "requiredPolicy": match network.get("requiredPolicy").and_then(Value::as_str) {
            Some("none") => json!("none"),
            Some(_) => json!({"redacted": true}),
            None => Value::Null,
        }
    })
}

fn projected_redaction(value: Option<&Value>) -> Value {
    let Some(Value::Object(redaction)) = value else {
        return Value::Null;
    };
    json!({
        "policy": redaction
            .get("policy")
            .and_then(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_STRING_BYTES))
            .unwrap_or(Value::Null)
    })
}

fn projected_limits(value: Option<&Value>) -> Value {
    let Some(Value::Object(limits)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "maxSummaryBytes",
        "maxRefItems",
        "maxPlaceholderBytes",
        "maxTotalPayloadBytes",
    ] {
        if let Some(number) = limits.get(key).and_then(Value::as_u64) {
            projected.insert(key.to_owned(), json!(number));
        }
    }
    Value::Object(projected)
}

fn projected_idempotency(value: Option<&Value>) -> Value {
    let Some(Value::Object(idempotency)) = value else {
        return Value::Null;
    };
    json!({"keyRedacted": idempotency.get("key").is_some()})
}

fn projected_string_array(value: Option<&Value>) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": MAX_REF_ITEMS});
    };
    json!({
        "items": items
            .iter()
            .take(MAX_REF_ITEMS)
            .filter_map(Value::as_str)
            .map(|text| projected_text(text, PROJECTION_ID_BYTES))
            .collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > MAX_REF_ITEMS,
        "maxItems": MAX_REF_ITEMS
    })
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
    if unsafe_projection_text(text) {
        return json!({"redacted": true, "bytes": text.len()});
    }
    let bounded = bounded_utf8(text, max_bytes);
    Value::String(bounded.text)
}

fn unsafe_projection_text(text: &str) -> bool {
    let lowered = text.to_ascii_lowercase();
    lowered.contains("bearer ")
        || lowered.contains("api_key=")
        || lowered.contains("apikey=")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("token=")
        || lowered.contains("credential=")
        || lowered.contains("authorization:")
        || lowered.contains("http://")
        || lowered.contains("https://")
        || lowered.contains("file://")
        || lowered.contains("/users/")
        || lowered.contains("/private/")
}

struct ProjectedText {
    text: String,
}

fn bounded_utf8(value: &str, max_bytes: usize) -> ProjectedText {
    if value.len() <= max_bytes {
        return ProjectedText {
            text: value.to_owned(),
        };
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    ProjectedText {
        text: value[..end].to_owned(),
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
