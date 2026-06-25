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
    IMPORT_PREVIEW_LIFECYCLE_TOPIC, IMPORT_PREVIEW_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{import_preview_summary, inspected_import_preview};
use super::validation::*;
use super::{Deps, IMPORT_PREVIEW_KIND, IMPORT_PREVIEW_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.import_preview.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.import_preview.idempotency.v1\0";

pub(crate) async fn record_import_preview_record_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_import_preview_fields(payload)?;
    ensure_write_authority(deps, invocation, "import_preview_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let preview_id = optional_string(payload, "previewId")?
        .map(|value| bounded_token("previewId", &value, PREVIEW_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let import_history_ref = required_ref_kind(
        payload,
        "importHistoryRef",
        "import_history_record",
        "import_history_record:",
    )?;
    let repository_tree_ref = required_ref_kind(
        payload,
        "repositoryTreeRef",
        "repository_tree_snapshot",
        "repository_tree_snapshot:",
    )?;
    let repository_ref = optional_ref(payload, "repositoryRef")?;
    let root_ref = optional_ref(payload, "rootRef")?;
    let preview_fingerprint = bounded_token(
        "previewFingerprint",
        &required_string(payload, "previewFingerprint")?,
        TOKEN_MAX_BYTES,
    )?;
    let head_ref = optional_ref(payload, "headRef")?;
    let preview_label = optional_string(payload, "previewLabel")?
        .map(|value| bounded_text("previewLabel", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let preview_summary = optional_string(payload, "previewSummary")?
        .map(|value| bounded_text("previewSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let change_summary = optional_string(payload, "changeSummary")?
        .map(|value| bounded_text("changeSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let path_entries =
        validate_path_entries(&optional_array(payload, "pathEntries")?.unwrap_or_default())?;
    let counts = preview_counts(payload, path_entries.len())?;
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    let source_refs = validate_ref_array("sourceRefs", &source_refs, MAX_SUPPORT_REFS)?;
    let evidence_refs = validate_ref_array("evidenceRefs", &evidence_refs, MAX_SUPPORT_REFS)?;
    let path_entry_count = path_entries.len();
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = import_preview_resource_id(&scope, &preview_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_import_preview(&existing, "import_preview_record replay")?;
        ensure_scope(&existing, &scope, "import_preview_record replay")?;
        let (version, payload) = current_payload(&existing, "import_preview_record replay")?;
        return Ok(json!({
            "schemaVersion": IMPORT_PREVIEW_SCHEMA_VERSION,
            "operation": "import_preview_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "importPreviewResourceId": resource_id,
            "importPreviewVersionId": version.version_id,
            "record": import_preview_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "import_preview")]
        }));
    }

    let record = import_preview_record(ImportPreviewRecordInput {
        preview_id: &preview_id,
        scope: &scope,
        import_history_ref,
        repository_tree_ref,
        repository_ref,
        root_ref,
        preview_fingerprint: &preview_fingerprint,
        head_ref,
        counts,
        path_entries,
        source_refs,
        evidence_refs,
        preview_label: preview_label.as_deref(),
        preview_summary: preview_summary.as_deref(),
        change_summary: change_summary.as_deref(),
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
            kind: IMPORT_PREVIEW_KIND.to_owned(),
            schema_id: Some(IMPORT_PREVIEW_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "import_preview_record".to_owned(),
                uri: format!("import-preview:{preview_id}"),
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
        .ok_or_else(|| invalid("import preview resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "import_preview.recorded",
        &resource,
        json!({
            "pathEntryCount": path_entry_count,
            "contentFreePreview": true,
            "rawImportPayloadStored": false,
            "rawPreviewPayloadStored": false,
            "rawRepositoryContentsStored": false,
            "absolutePathsStored": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": IMPORT_PREVIEW_SCHEMA_VERSION,
        "operation": "import_preview_record",
        "status": "active",
        "idempotentReplay": false,
        "importPreviewResourceId": resource.resource_id,
        "importPreviewVersionId": version_id,
        "record": import_preview_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "import_preview")]
    }))
}

pub(crate) async fn list_import_preview_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "import_preview_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let repository_ref_id = optional_string(payload, "repositoryRefId")?
        .map(|value| bounded_token("repositoryRefId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let import_history_ref_id = optional_string(payload, "importHistoryRefId")?
        .map(|value| bounded_token("importHistoryRefId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let repository_tree_ref_id = optional_string(payload, "repositoryTreeRefId")?
        .map(|value| bounded_token("repositoryTreeRefId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(IMPORT_PREVIEW_KIND.to_owned()),
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
        ensure_import_preview(&inspection, "import_preview_list")?;
        ensure_scope(&inspection, &scope, "import_preview_list")?;
        let (version, payload) = current_payload(&inspection, "import_preview_list")?;
        if repository_ref_id.as_deref().is_some_and(|value| {
            payload
                .get("repositoryRef")
                .and_then(|repository| repository.get("id"))
                .or_else(|| {
                    payload
                        .get("repositoryRef")
                        .and_then(|repository| repository.get("resourceId"))
                })
                .and_then(Value::as_str)
                .is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        if ref_id_mismatch(
            payload.get("importHistoryRef"),
            import_history_ref_id.as_deref(),
        ) || ref_id_mismatch(
            payload.get("repositoryTreeRef"),
            repository_tree_ref_id.as_deref(),
        ) {
            continue;
        }
        records.push(import_preview_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": IMPORT_PREVIEW_SCHEMA_VERSION,
        "operation": "import_preview_list",
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

fn ref_id_mismatch(ref_value: Option<&Value>, expected: Option<&str>) -> bool {
    expected.is_some_and(|expected| {
        ref_value
            .and_then(|value| {
                value
                    .get("id")
                    .or_else(|| value.get("resourceId"))
                    .and_then(Value::as_str)
            })
            .is_some_and(|actual| actual != expected)
    })
}

pub(crate) async fn inspect_import_preview_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "import_preview_inspect").await?;
    let resource_id = required_string(payload, "importPreviewResourceId")?;
    validate_import_preview_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing import preview record {resource_id}")))?;
    ensure_import_preview(&inspection, "import_preview_inspect")?;
    ensure_scope(&inspection, &scope, "import_preview_inspect")?;
    let (version, payload) = current_payload(&inspection, "import_preview_inspect")?;
    Ok(json!({
        "schemaVersion": IMPORT_PREVIEW_SCHEMA_VERSION,
        "operation": "import_preview_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_import_preview(&inspection.resource, version, payload)
    }))
}

struct ImportPreviewRecordInput<'a> {
    preview_id: &'a str,
    scope: &'a EngineResourceScope,
    import_history_ref: Value,
    repository_tree_ref: Value,
    repository_ref: Option<Value>,
    root_ref: Option<Value>,
    preview_fingerprint: &'a str,
    head_ref: Option<Value>,
    counts: Value,
    path_entries: Vec<Value>,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    preview_label: Option<&'a str>,
    preview_summary: Option<&'a str>,
    change_summary: Option<&'a str>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn import_preview_record(input: ImportPreviewRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": IMPORT_PREVIEW_SCHEMA_VERSION,
        "state": "active",
        "previewId": input.preview_id,
        "scope": scope_ref(input.scope),
        "importHistoryRef": input.import_history_ref,
        "repositoryTreeRef": input.repository_tree_ref,
        "previewFingerprint": input.preview_fingerprint,
        "counts": input.counts,
        "pathEntries": input.path_entries,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "rawImportPayloadStored": false,
            "rawPreviewPayloadStored": false,
            "rawRepositoryContentsStored": false,
            "rawBlobBytesStored": false,
            "absolutePathsStored": false,
            "contentFreePreview": true,
            "importExecutionPerformed": false,
            "gitMutationPerformed": false,
            "nativeTreeRequired": false
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
    if let Some(head_ref) = input.head_ref {
        record["headRef"] = head_ref;
    }
    if let Some(repository_ref) = input.repository_ref {
        record["repositoryRef"] = repository_ref;
    }
    if let Some(root_ref) = input.root_ref {
        record["rootRef"] = root_ref;
    }
    if let Some(preview_label) = input.preview_label {
        record["metadata"]["previewLabel"] = json!(preview_label);
    }
    if let Some(preview_summary) = input.preview_summary {
        record["metadata"]["previewSummary"] = json!(preview_summary);
    }
    if let Some(change_summary) = input.change_summary {
        record["metadata"]["changeSummary"] = json!(change_summary);
    }
    record
}

async fn import_preview_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created import preview resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "import_preview_record projection")?;
    Ok(import_preview_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_import_preview(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != IMPORT_PREVIEW_KIND {
        return Err(invalid(format!(
            "{operation} expected {IMPORT_PREVIEW_KIND}"
        )));
    }
    if inspection.resource.schema_id != IMPORT_PREVIEW_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {IMPORT_PREVIEW_SCHEMA_ID}"
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
            "{operation} cannot access import preview outside the current scope"
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

fn validate_import_preview_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{IMPORT_PREVIEW_KIND}:")) {
        return Err(invalid(
            "importPreviewResourceId has unsupported resource kind",
        ));
    }
    bounded_token("importPreviewResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
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
            topic: IMPORT_PREVIEW_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                    "event": event_type,
            "resource": resource_ref(resource, "subject"),
            "details": payload,
            "importPreviewBoundary": {
                "contentFreePreview": true,
                "rawImportPayloadStored": false,
                "rawPreviewPayloadStored": false,
                "rawRepositoryContentsStored": false,
                "absolutePathsStored": false,
                "importExecutionPerformed": false,
                "gitMutationPerformed": false,
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

fn import_preview_resource_id(
    scope: &EngineResourceScope,
    preview_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(preview_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{IMPORT_PREVIEW_KIND}:{}", hex::encode(hasher.finalize()))
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
        "kind": IMPORT_PREVIEW_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresImportPreviewMetadataOnly": true,
        "contentFreePreview": true,
        "rawImportPayloadStored": false,
        "rawPreviewPayloadStored": false,
        "rawRepositoryContentsStored": false,
        "absolutePathsStored": false,
        "importExecutionPerformed": false,
        "gitMutationPerformed": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [IMPORT_PREVIEW_KIND],
        "wildcardGrantsAllowed": false,
        "contentFreePreview": true,
        "importExecutionPerformed": false,
        "gitMutationPerformed": false
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

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(|error| invalid(format!("worker id: {error}")))
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
