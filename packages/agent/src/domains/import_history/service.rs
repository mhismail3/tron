use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources, PublishStreamEvent,
    WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{ensure_write_authority, inspect_read_grant};
use super::contract::{
    IMPORT_HISTORY_LIFECYCLE_TOPIC, IMPORT_HISTORY_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{import_history_summary, inspected_import_history};
use super::validation::*;
use super::{Deps, IMPORT_HISTORY_RECORD_KIND, IMPORT_HISTORY_RECORD_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.import_history.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.import_history.idempotency.v1\0";

pub(crate) async fn record_import_history_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_import_fields(payload)?;
    ensure_write_authority(deps, invocation, "import_history_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let record_id = optional_string(payload, "recordId")?
        .map(|value| bounded_token("recordId", &value, RECORD_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let graph_kind = parse_graph_kind(optional_string(payload, "graphKind")?)?;
    let subject_kind = parse_subject_kind(optional_string(payload, "subjectKind")?)?;
    let subject_id = required_string(payload, "subjectId")?;
    validate_subject(invocation, subject_kind, &subject_id)?;
    let render_hint = parse_render_hint(optional_string(payload, "renderHint")?)?;
    let lineage_label = optional_string(payload, "lineageLabel")?
        .map(|value| bounded_text("lineageLabel", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let lineage_summary = optional_string(payload, "lineageSummary")?
        .map(|value| bounded_text("lineageSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let import_source_kind = optional_string(payload, "importSourceKind")?
        .map(|value| bounded_token("importSourceKind", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let parent_refs = optional_array(payload, "parentRefs")?.unwrap_or_default();
    let child_refs = optional_array(payload, "childRefs")?.unwrap_or_default();
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    validate_ref_array("parentRefs", &parent_refs, MAX_PARENT_REFS)?;
    validate_ref_array("childRefs", &child_refs, MAX_CHILD_REFS)?;
    validate_ref_array("sourceRefs", &source_refs, MAX_SUPPORT_REFS)?;
    validate_ref_array("evidenceRefs", &evidence_refs, MAX_SUPPORT_REFS)?;
    let parent_count = resource_payload_count(&parent_refs);
    let child_count = resource_payload_count(&child_refs);
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = import_history_resource_id(&scope, &record_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_import_history(&existing, "import_history_record replay")?;
        ensure_scope(&existing, &scope, "import_history_record replay")?;
        let (version, payload) = current_payload(&existing, "import_history_record replay")?;
        return Ok(json!({
            "schemaVersion": IMPORT_HISTORY_SCHEMA_VERSION,
            "operation": "import_history_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "importHistoryResourceId": resource_id,
            "importHistoryVersionId": version.version_id,
            "record": import_history_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "import_history")]
        }));
    }

    let record = import_history_record(ImportHistoryRecordInput {
        record_id: &record_id,
        graph_kind: &graph_kind,
        scope: &scope,
        subject_kind,
        subject_id: &subject_id,
        parent_refs,
        child_refs,
        source_refs,
        evidence_refs,
        lineage_label: lineage_label.as_deref(),
        lineage_summary: lineage_summary.as_deref(),
        render_hint: &render_hint,
        import_source_kind: import_source_kind.as_deref(),
        created_at: &now,
        updated_at: &now,
        retention,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: IMPORT_HISTORY_RECORD_KIND.to_owned(),
            schema_id: Some(IMPORT_HISTORY_RECORD_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "lineage".to_owned(),
                uri: format!("lineage:{record_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("import history resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "import_history.recorded",
        &resource,
        json!({
            "graphKind": graph_kind,
            "subjectKind": subject_kind.as_str(),
            "parentCount": parent_count,
            "childCount": child_count,
            "genericGraphOnly": true,
            "rawImportPayloadStored": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": IMPORT_HISTORY_SCHEMA_VERSION,
        "operation": "import_history_record",
        "status": "active",
        "idempotentReplay": false,
        "importHistoryResourceId": resource.resource_id,
        "importHistoryVersionId": version_id,
        "record": import_history_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "import_history")]
    }))
}

pub(crate) async fn list_import_history_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "import_history_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let graph_kind = optional_string(payload, "graphKind")?;
    let subject_kind = optional_string(payload, "subjectKind")?;
    let subject_id = optional_string(payload, "subjectId")?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(IMPORT_HISTORY_RECORD_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: if include_archived {
                None
            } else {
                Some("active".to_owned())
            },
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut records = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_import_history(&inspection, "import_history_list")?;
        ensure_scope(&inspection, &scope, "import_history_list")?;
        let (version, payload) = current_payload(&inspection, "import_history_list")?;
        if graph_kind.as_deref().is_some_and(|value| {
            payload
                .get("graphKind")
                .and_then(Value::as_str)
                .is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        if subject_kind.as_deref().is_some_and(|value| {
            payload
                .get("subjectRef")
                .and_then(|subject| subject.get("kind"))
                .and_then(Value::as_str)
                .is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        if subject_id.as_deref().is_some_and(|value| {
            payload
                .get("subjectRef")
                .and_then(|subject| subject.get("id"))
                .or_else(|| {
                    payload
                        .get("subjectRef")
                        .and_then(|subject| subject.get("resourceId"))
                })
                .and_then(Value::as_str)
                .is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        records.push(import_history_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": IMPORT_HISTORY_SCHEMA_VERSION,
        "operation": "import_history_list",
        "scope": scope_ref(&scope),
        "records": records,
        "limits": {
            "requestedLimit": limit,
            "returned": records.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        }
    }))
}

pub(crate) async fn inspect_import_history_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "import_history_inspect").await?;
    let resource_id = required_string(payload, "importHistoryResourceId")?;
    validate_import_history_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing import history record {resource_id}")))?;
    ensure_import_history(&inspection, "import_history_inspect")?;
    ensure_scope(&inspection, &scope, "import_history_inspect")?;
    let (version, payload) = current_payload(&inspection, "import_history_inspect")?;
    Ok(json!({
        "schemaVersion": IMPORT_HISTORY_SCHEMA_VERSION,
        "operation": "import_history_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_import_history(&inspection.resource, version, payload)
    }))
}

struct ImportHistoryRecordInput<'a> {
    record_id: &'a str,
    graph_kind: &'a str,
    scope: &'a EngineResourceScope,
    subject_kind: SubjectKind,
    subject_id: &'a str,
    parent_refs: Vec<Value>,
    child_refs: Vec<Value>,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    lineage_label: Option<&'a str>,
    lineage_summary: Option<&'a str>,
    render_hint: &'a str,
    import_source_kind: Option<&'a str>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn import_history_record(input: ImportHistoryRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": IMPORT_HISTORY_SCHEMA_VERSION,
        "state": "active",
        "recordId": input.record_id,
        "graphKind": input.graph_kind,
        "scope": scope_ref(input.scope),
        "subjectRef": {
            "kind": input.subject_kind.as_str(),
            "id": input.subject_id,
            "role": "subject"
        },
        "parentRefs": input.parent_refs,
        "childRefs": input.child_refs,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "renderHint": input.render_hint,
            "rawImportPayloadStored": false,
            "rawRepositoryTreeStored": false,
            "nativeTreeRequired": false,
            "genericGraphOnly": true
        },
        "refs": {
            "source": input.source_refs,
            "evidence": input.evidence_refs
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(input.invocation),
        "idempotency": idempotency_evidence(input.invocation, input.idempotency_key),
        "revision": input.revision
    });
    if let Some(lineage_label) = input.lineage_label {
        record["metadata"]["lineageLabel"] = json!(lineage_label);
    }
    if let Some(lineage_summary) = input.lineage_summary {
        record["metadata"]["lineageSummary"] = json!(lineage_summary);
    }
    if let Some(import_source_kind) = input.import_source_kind {
        record["metadata"]["importSourceKind"] = json!(import_source_kind);
    }
    record
}

async fn import_history_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created import history resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "import_history_record projection")?;
    Ok(import_history_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_import_history(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != IMPORT_HISTORY_RECORD_KIND {
        return Err(invalid(format!(
            "{operation} expected {IMPORT_HISTORY_RECORD_KIND}"
        )));
    }
    if inspection.resource.schema_id != IMPORT_HISTORY_RECORD_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {IMPORT_HISTORY_RECORD_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot access import history outside the current scope"
        )));
    }
    Ok(())
}

fn current_payload<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))?;
    Ok((version, &version.payload))
}

fn validate_import_history_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{IMPORT_HISTORY_RECORD_KIND}:")) {
        return Err(invalid(
            "importHistoryResourceId has unsupported resource kind",
        ));
    }
    bounded_token("importHistoryResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: IMPORT_HISTORY_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "graphBoundary": {
                    "genericGraphOnly": true,
                    "rawImportPayloadStored": false,
                    "nativeTreeRequired": false
                }
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}

fn import_history_resource_id(
    scope: &EngineResourceScope,
    record_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(record_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!(
        "{IMPORT_HISTORY_RECORD_KIND}:{}",
        hex::encode(hasher.finalize())
    )
}

fn idempotency_evidence(invocation: &Invocation, idempotency_key: &str) -> Value {
    json!({
        "fingerprint": idempotency_fingerprint(idempotency_key),
        "fingerprintAlgorithm": IDEMPOTENCY_FINGERPRINT_ALGORITHM,
        "keyRedacted": true,
        "rawKeyStored": false,
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })
}

fn idempotency_fingerprint(idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

fn resource_policy() -> Value {
    json!({
        "owner": WORKER,
        "kind": IMPORT_HISTORY_RECORD_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresGraphRefsOnly": true,
        "genericGraphOnly": true,
        "rawImportPayloadStored": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [IMPORT_HISTORY_RECORD_KIND],
        "wildcardGrantsAllowed": false,
        "genericGraphOnly": true
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role
    })
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "role": role
    })
}

fn resource_payload_count(values: &[Value]) -> usize {
    values.len()
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(|error| invalid(format!("worker id: {error}")))
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
