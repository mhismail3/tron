use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;
const MAX_PROJECTED_LABELS: usize = 16;

pub(super) fn request_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "webResearchRequestResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
        "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
        "research": projected_research(payload.get("research")),
        "refs": projected_refs_object(payload.get("refs")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "web_research_request")]
    })
}

pub(super) fn reviewed_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "webResearchReviewResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "reviewId": projected_string(payload, "reviewId", PROJECTION_ID_BYTES),
        "request": projected_ref(payload.get("request")),
        "review": projected_review(payload.get("review")),
        "refs": projected_refs_object(payload.get("refs")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "web_research_review")]
    })
}

pub(super) fn source_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "webResearchSourceResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "sourceArtifactId": projected_string(payload, "sourceArtifactId", PROJECTION_ID_BYTES),
        "request": projected_ref(payload.get("request")),
        "review": projected_ref(payload.get("review")),
        "artifact": projected_artifact(payload.get("artifact")),
        "refs": projected_refs_object(payload.get("refs")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "web_research_source")]
    })
}

pub(super) fn inspected_request(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    inspected_common(
        resource,
        version,
        "request",
        request_summary(resource, version, payload),
        payload,
    )
}

pub(super) fn inspected_review(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    inspected_common(
        resource,
        version,
        "review",
        reviewed_summary(resource, version, payload),
        payload,
    )
}

pub(super) fn inspected_source(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    inspected_common(
        resource,
        version,
        "source",
        source_summary(resource, version, payload),
        payload,
    )
}

fn inspected_common(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    key: &str,
    summary: Value,
    payload: &Value,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        key: summary,
        "traceRefs": projected_refs(payload.get("traceRefs")),
        "replayRefs": projected_refs(payload.get("replayRefs")),
        "authority": projected_authority(payload.get("authority")),
        "idempotency": projected_idempotency(payload.get("idempotency")),
        "sideEffectProof": projected_side_effect_proof(payload.get("sideEffectProof")),
        "projection": projection_policy(),
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_research(value: Option<&Value>) -> Value {
    let Some(Value::Object(research)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["questionSummary", "scopeSummary", "networkPolicy"] {
        insert_projected_string(research, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(labels) = research.get("policyLabels") {
        projected.insert("policyLabels".to_owned(), projected_labels(labels));
    }
    for key in [
        "browserAutomationRequested",
        "searchProviderIntegration",
        "cookieReuseRequested",
        "rawPageCaptureStored",
    ] {
        insert_projected_bool(research, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_review(value: Option<&Value>) -> Value {
    let Some(Value::Object(review)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["outcome", "summary", "networkPolicy"] {
        insert_projected_string(review, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(labels) = review.get("policyLabels") {
        projected.insert("policyLabels".to_owned(), projected_labels(labels));
    }
    for key in ["metadataOnly", "independentAcceptance"] {
        insert_projected_bool(review, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_artifact(value: Option<&Value>) -> Value {
    let Some(Value::Object(artifact)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["kind", "title", "summary", "networkPolicy"] {
        insert_projected_string(artifact, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(labels) = artifact.get("policyLabels") {
        projected.insert("policyLabels".to_owned(), projected_labels(labels));
    }
    for key in [
        "boundedSummaryOnly",
        "rawHtmlStored",
        "pageDumpStored",
        "browserLogsStored",
        "cookiesStored",
    ] {
        insert_projected_bool(artifact, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_refs_object(value: Option<&Value>) -> Value {
    let Some(Value::Object(refs)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "sourceRefs",
        "citationRefs",
        "robotsEvidenceRefs",
        "dependencyRequestRefs",
        "currentScopeRefs",
        "evidenceRefs",
    ] {
        if let Some(value) = refs.get(key) {
            projected.insert(key.to_owned(), projected_refs(Some(value)));
        }
    }
    Value::Object(projected)
}

fn projected_side_effect_proof(value: Option<&Value>) -> Value {
    let Some(Value::Object(proof)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "metadataOnly",
        "networkAccessPerformed",
        "browserAutomationPerformed",
        "searchPerformed",
        "crawlPerformed",
        "loginOrCookieReusePerformed",
        "rawHtmlStored",
        "pageDumpStored",
        "browserLogsStored",
        "cookiesStored",
        "credentialsStored",
        "rawLocalPathsStored",
        "rawCommandsStored",
        "rawCodeOrFileContentsStored",
        "rawGrantIdsStored",
        "rawAuthorityIdsStored",
        "packageManagerOutputStored",
        "rawDependencyArtifactsStored",
    ] {
        insert_projected_bool(proof, &mut projected, key);
    }
    insert_projected_string(proof, &mut projected, "networkPolicy", PROJECTION_ID_BYTES);
    Value::Object(projected)
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "grantRedacted",
        "rawAuthorityIdsStored",
        "derivedRuntimeGrantRequired",
    ] {
        insert_projected_bool(authority, &mut projected, key);
    }
    if let Some(scopes) = authority.get("requiredScopes") {
        projected.insert("requiredScopes".to_owned(), projected_labels(scopes));
    }
    if let Some(kinds) = authority.get("resourceKinds") {
        projected.insert("resourceKinds".to_owned(), projected_labels(kinds));
    }
    insert_projected_bool(authority, &mut projected, "wildcardGrantsAllowed");
    Value::Object(projected)
}

fn projected_idempotency(value: Option<&Value>) -> Value {
    let Some(Value::Object(idempotency)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["fingerprint", "fingerprintAlgorithm"] {
        insert_projected_string(idempotency, &mut projected, key, PROJECTION_ID_BYTES);
    }
    insert_projected_bool(idempotency, &mut projected, "keyRedacted");
    insert_projected_bool(idempotency, &mut projected, "rawKeyStored");
    Value::Object(projected)
}

fn projected_refs(value: Option<&Value>) -> Value {
    let Some(Value::Array(refs)) = value else {
        return Value::Array(Vec::new());
    };
    Value::Array(
        refs.iter()
            .take(MAX_PROJECTED_REFS)
            .filter_map(|value| match value {
                Value::Object(map) => Some(projected_ref_object(map)),
                _ => None,
            })
            .collect(),
    )
}

fn projected_ref(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Object(map)) => projected_ref_object(map),
        _ => Value::Null,
    }
}

fn projected_ref_object(map: &Map<String, Value>) -> Value {
    let mut projected = Map::new();
    for key in [
        "kind",
        "resourceId",
        "role",
        "schemaId",
        "lifecycle",
        "currentVersionId",
        "versionId",
        "payloadHash",
        "summary",
    ] {
        insert_projected_string(map, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
}

fn projected_labels(value: &Value) -> Value {
    let Some(labels) = value.as_array() else {
        return Value::Array(Vec::new());
    };
    Value::Array(
        labels
            .iter()
            .take(MAX_PROJECTED_LABELS)
            .filter_map(|value| value.as_str())
            .map(|value| json!(truncate(value, PROJECTION_ID_BYTES)))
            .collect(),
    )
}

fn projected_fingerprint(payload: &Value) -> Value {
    payload
        .pointer("/idempotency/fingerprint")
        .and_then(Value::as_str)
        .map(|value| json!(truncate(value, PROJECTION_ID_BYTES)))
        .unwrap_or(Value::Null)
}

fn projected_string(payload: &Value, key: &str, max_bytes: usize) -> Value {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|value| json!(truncate(value, max_bytes)))
        .unwrap_or(Value::Null)
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|value| json!(truncate(value, PROJECTION_ID_BYTES)))
        .unwrap_or_else(|| json!(resource.lifecycle))
}

fn insert_projected_string(
    source: &Map<String, Value>,
    target: &mut Map<String, Value>,
    key: &str,
    max_bytes: usize,
) {
    if let Some(value) = source.get(key).and_then(Value::as_str) {
        target.insert(key.to_owned(), json!(truncate(value, max_bytes)));
    }
}

fn insert_projected_bool(source: &Map<String, Value>, target: &mut Map<String, Value>, key: &str) {
    if let Some(value) = source.get(key).and_then(Value::as_bool) {
        target.insert(key.to_owned(), json!(value));
    }
}

fn projection_policy() -> Value {
    json!({
        "providerSafe": true,
        "rawHtmlVisible": false,
        "pageDumpsVisible": false,
        "browserLogsVisible": false,
        "cookiesVisible": false,
        "credentialsVisible": false,
        "rawLocalMaterialVisible": false,
        "rawGrantIdsVisible": false,
        "rawAuthorityIdsVisible": false
    })
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payloadHash": version.content_hash,
    })
}

fn truncate(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}
