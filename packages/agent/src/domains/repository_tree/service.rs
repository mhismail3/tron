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
    READ_SCOPE, REPOSITORY_TREE_LIFECYCLE_TOPIC, REPOSITORY_TREE_SCHEMA_VERSION,
    RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_repository_tree, repository_tree_summary};
use super::validation::*;
use super::{Deps, REPOSITORY_TREE_SNAPSHOT_KIND, REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.repository_tree.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.repository_tree.idempotency.v1\0";

pub(crate) async fn record_repository_tree_snapshot_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_repository_tree_fields(payload)?;
    ensure_write_authority(deps, invocation, "repository_tree_snapshot").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let snapshot_id = optional_string(payload, "snapshotId")?
        .map(|value| bounded_token("snapshotId", &value, SNAPSHOT_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let repository_ref = required_ref(payload, "repositoryRef")?;
    let root_ref = required_ref(payload, "rootRef")?;
    let tree_object_ref = bounded_token(
        "treeObjectRef",
        &required_string(payload, "treeObjectRef")?,
        TOKEN_MAX_BYTES,
    )?;
    let head_ref = optional_ref(payload, "headRef")?;
    let snapshot_label = optional_string(payload, "snapshotLabel")?
        .map(|value| bounded_text("snapshotLabel", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let snapshot_summary = optional_string(payload, "snapshotSummary")?
        .map(|value| bounded_text("snapshotSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let path_entries =
        validate_path_entries(&optional_array(payload, "pathEntries")?.unwrap_or_default())?;
    let counts = tree_counts(payload, path_entries.len())?;
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    let source_refs = validate_ref_array("sourceRefs", &source_refs, MAX_SUPPORT_REFS)?;
    let evidence_refs = validate_ref_array("evidenceRefs", &evidence_refs, MAX_SUPPORT_REFS)?;
    let path_entry_count = path_entries.len();
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = repository_tree_resource_id(&scope, &snapshot_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_repository_tree(&existing, "repository_tree_snapshot replay")?;
        ensure_scope(&existing, &scope, "repository_tree_snapshot replay")?;
        let (version, payload) = current_payload(&existing, "repository_tree_snapshot replay")?;
        return Ok(json!({
            "schemaVersion": REPOSITORY_TREE_SCHEMA_VERSION,
            "operation": "repository_tree_snapshot",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "repositoryTreeResourceId": resource_id,
            "repositoryTreeVersionId": version.version_id,
            "record": repository_tree_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "repository_tree")]
        }));
    }

    let record = repository_tree_snapshot(RepositoryTreeRecordInput {
        snapshot_id: &snapshot_id,
        scope: &scope,
        repository_ref,
        root_ref,
        tree_object_ref: &tree_object_ref,
        head_ref,
        counts,
        path_entries,
        source_refs,
        evidence_refs,
        snapshot_label: snapshot_label.as_deref(),
        snapshot_summary: snapshot_summary.as_deref(),
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
            kind: REPOSITORY_TREE_SNAPSHOT_KIND.to_owned(),
            schema_id: Some(REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "repository_tree_snapshot".to_owned(),
                uri: format!("repository-tree:{snapshot_id}"),
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
        .ok_or_else(|| invalid("repository tree resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "repository_tree.recorded",
        &resource,
        json!({
            "pathEntryCount": path_entry_count,
            "contentFreeSnapshot": true,
            "rawRepositoryContentsStored": false,
            "absolutePathsStored": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": REPOSITORY_TREE_SCHEMA_VERSION,
        "operation": "repository_tree_snapshot",
        "status": "active",
        "idempotentReplay": false,
        "repositoryTreeResourceId": resource.resource_id,
        "repositoryTreeVersionId": version_id,
        "record": repository_tree_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "repository_tree")]
    }))
}

pub(crate) async fn list_repository_tree_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "repository_tree_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let repository_ref_id = optional_string(payload, "repositoryRefId")?
        .map(|value| bounded_token("repositoryRefId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(REPOSITORY_TREE_SNAPSHOT_KIND.to_owned()),
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
        ensure_repository_tree(&inspection, "repository_tree_list")?;
        ensure_scope(&inspection, &scope, "repository_tree_list")?;
        let (version, payload) = current_payload(&inspection, "repository_tree_list")?;
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
        records.push(repository_tree_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": REPOSITORY_TREE_SCHEMA_VERSION,
        "operation": "repository_tree_list",
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

pub(crate) async fn inspect_repository_tree_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "repository_tree_inspect").await?;
    let resource_id = required_string(payload, "repositoryTreeResourceId")?;
    validate_repository_tree_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing repository tree record {resource_id}")))?;
    ensure_repository_tree(&inspection, "repository_tree_inspect")?;
    ensure_scope(&inspection, &scope, "repository_tree_inspect")?;
    let (version, payload) = current_payload(&inspection, "repository_tree_inspect")?;
    Ok(json!({
        "schemaVersion": REPOSITORY_TREE_SCHEMA_VERSION,
        "operation": "repository_tree_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_repository_tree(&inspection.resource, version, payload)
    }))
}

struct RepositoryTreeRecordInput<'a> {
    snapshot_id: &'a str,
    scope: &'a EngineResourceScope,
    repository_ref: Value,
    root_ref: Value,
    tree_object_ref: &'a str,
    head_ref: Option<Value>,
    counts: Value,
    path_entries: Vec<Value>,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    snapshot_label: Option<&'a str>,
    snapshot_summary: Option<&'a str>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn repository_tree_snapshot(input: RepositoryTreeRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": REPOSITORY_TREE_SCHEMA_VERSION,
        "state": "active",
        "snapshotId": input.snapshot_id,
        "scope": scope_ref(input.scope),
        "repositoryRef": input.repository_ref,
        "rootRef": input.root_ref,
        "treeObjectRef": input.tree_object_ref,
        "counts": input.counts,
        "pathEntries": input.path_entries,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "rawImportPayloadStored": false,
            "rawRepositoryTreeStored": false,
            "rawRepositoryContentsStored": false,
            "rawBlobBytesStored": false,
            "absolutePathsStored": false,
            "contentFreeSnapshot": true,
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
    if let Some(snapshot_label) = input.snapshot_label {
        record["metadata"]["snapshotLabel"] = json!(snapshot_label);
    }
    if let Some(snapshot_summary) = input.snapshot_summary {
        record["metadata"]["snapshotSummary"] = json!(snapshot_summary);
    }
    record
}

async fn repository_tree_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created repository tree resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "repository_tree_snapshot projection")?;
    Ok(repository_tree_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_repository_tree(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != REPOSITORY_TREE_SNAPSHOT_KIND {
        return Err(invalid(format!(
            "{operation} expected {REPOSITORY_TREE_SNAPSHOT_KIND}"
        )));
    }
    if inspection.resource.schema_id != REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID}"
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
            "{operation} cannot access repository tree outside the current scope"
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

fn validate_repository_tree_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{REPOSITORY_TREE_SNAPSHOT_KIND}:")) {
        return Err(invalid(
            "repositoryTreeResourceId has unsupported resource kind",
        ));
    }
    bounded_token("repositoryTreeResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
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
            topic: REPOSITORY_TREE_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                    "event": event_type,
            "resource": resource_ref(resource, "subject"),
            "details": payload,
            "repositoryTreeBoundary": {
                "contentFreeSnapshot": true,
                "rawImportPayloadStored": false,
                "rawRepositoryContentsStored": false,
                "absolutePathsStored": false,
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

fn repository_tree_resource_id(
    scope: &EngineResourceScope,
    snapshot_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(snapshot_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!(
        "{REPOSITORY_TREE_SNAPSHOT_KIND}:{}",
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
        "kind": REPOSITORY_TREE_SNAPSHOT_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresRepositoryTreeMetadataOnly": true,
        "contentFreeSnapshot": true,
        "rawRepositoryContentsStored": false,
        "absolutePathsStored": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [REPOSITORY_TREE_SNAPSHOT_KIND],
        "wildcardGrantsAllowed": false,
        "contentFreeSnapshot": true
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
