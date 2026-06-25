use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources, PublishStreamEvent,
    UpdateResource, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{ensure_write_authority, inspect_read_grant};
use super::contract::{
    MEDIA_LIFECYCLE_TOPIC, MEDIA_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_media, media_summary};
use super::validation::*;
use super::{Deps, MEDIA_ARTIFACT_KIND, MEDIA_ARTIFACT_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.media.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.media.idempotency.v1\0";

pub(crate) async fn create_media_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_media_fields(payload)?;
    ensure_write_authority(deps, invocation, "media_create").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let media_id = optional_string(payload, "mediaId")?
        .map(|value| bounded_token("mediaId", &value, MEDIA_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let media_kind = parse_media_kind(optional_string(payload, "mediaKind")?)?;
    let mime_type = required_string(payload, "mimeType")?;
    let size_bytes =
        optional_u64(payload, "sizeBytes")?.ok_or_else(|| invalid("sizeBytes is required"))?;
    validate_mime_and_size(media_kind, &mime_type, size_bytes)?;
    let blob_ref = bounded_token(
        "blobRef",
        &required_string(payload, "blobRef")?,
        STORAGE_REF_MAX_BYTES,
    )?;
    let content_hash = optional_string(payload, "contentHash")?
        .map(|value| bounded_token("contentHash", &value, CONTENT_HASH_MAX_BYTES))
        .transpose()?;
    let title = optional_string(payload, "title")?
        .map(|value| bounded_text("title", &value, TITLE_MAX_BYTES))
        .transpose()?;
    let summary = optional_string(payload, "summary")?
        .map(|value| bounded_text("summary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let duration_ms = optional_u64(payload, "durationMs")?;
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    validate_refs("sourceRefs", &source_refs)?;
    validate_refs("evidenceRefs", &evidence_refs)?;
    let retention = retention_policy(payload)?;
    let transcription = transcription_record(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = media_resource_id(&scope, &media_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_media(&existing, "media_create replay")?;
        ensure_scope(&existing, &scope, "media_create replay")?;
        let (version, payload) = current_payload(&existing, "media_create replay")?;
        return Ok(json!({
            "schemaVersion": MEDIA_SCHEMA_VERSION,
            "operation": "media_create",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "mediaResourceId": resource_id,
            "mediaVersionId": version.version_id,
            "media": media_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "media")]
        }));
    }

    let record = media_record(MediaRecordInput {
        state: "active",
        media_id: &media_id,
        media_kind,
        mime_type: &mime_type,
        size_bytes,
        title: title.as_deref(),
        summary: summary.as_deref(),
        duration_ms,
        blob_ref: &blob_ref,
        content_hash: content_hash.as_deref(),
        scope: &scope,
        retention,
        transcription,
        source_refs,
        evidence_refs,
        created_at: &now,
        updated_at: &now,
        archived_at: None,
        archive_reason: None,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MEDIA_ARTIFACT_KIND.to_owned(),
            schema_id: Some(MEDIA_ARTIFACT_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "blob".to_owned(),
                uri: blob_ref.clone(),
                mime_type: Some(mime_type.clone()),
                size_bytes: Some(size_bytes),
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("media resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "media.created",
        &resource,
        json!({
            "state": "active",
            "mediaKind": media_kind.as_str(),
            "mimeType": mime_type,
            "sizeBytes": size_bytes,
            "rawAudioProviderProjection": "not_sent"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEDIA_SCHEMA_VERSION,
        "operation": "media_create",
        "status": "active",
        "idempotentReplay": false,
        "mediaResourceId": resource.resource_id,
        "mediaVersionId": version_id,
        "media": media_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "media")]
    }))
}

pub(crate) async fn list_media_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "media_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let media_kind = optional_string(payload, "mediaKind")?
        .map(|value| parse_media_kind(Some(value)))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MEDIA_ARTIFACT_KIND.to_owned()),
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
    let mut media = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_media(&inspection, "media_list")?;
        ensure_scope(&inspection, &scope, "media_list")?;
        let (version, payload) = current_payload(&inspection, "media_list")?;
        if media_kind.is_some_and(|kind| {
            payload
                .get("mediaKind")
                .and_then(Value::as_str)
                .is_some_and(|value| value != kind.as_str())
        }) {
            continue;
        }
        media.push(media_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": MEDIA_SCHEMA_VERSION,
        "operation": "media_list",
        "scope": scope_ref(&scope),
        "media": media,
        "limits": {
            "requestedLimit": limit,
            "returned": media.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        }
    }))
}

pub(crate) async fn inspect_media_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "media_inspect").await?;
    let resource_id = required_string(payload, "mediaResourceId")?;
    validate_media_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing media artifact {resource_id}")))?;
    ensure_media(&inspection, "media_inspect")?;
    ensure_scope(&inspection, &scope, "media_inspect")?;
    let (version, payload) = current_payload(&inspection, "media_inspect")?;
    Ok(json!({
        "schemaVersion": MEDIA_SCHEMA_VERSION,
        "operation": "media_inspect",
        "scope": scope_ref(&scope),
        "media": inspected_media(&inspection.resource, version, payload)
    }))
}

pub(crate) async fn archive_media_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    ensure_write_authority(deps, invocation, "media_archive").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let resource_id = required_string(payload, "mediaResourceId")?;
    validate_media_resource_id(&resource_id)?;
    let reason = optional_string(payload, "reason")?
        .map(|value| bounded_text("reason", &value, REASON_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "archive".to_owned());
    let scope = resource_scope(invocation)?;
    let mut inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing media artifact {resource_id}")))?;
    ensure_media(&inspection, "media_archive")?;
    ensure_scope(&inspection, &scope, "media_archive")?;
    let (current_version, current) = current_payload(&inspection, "media_archive")?;
    if optional_string(payload, "expectedMediaVersionId")?
        .is_some_and(|expected| expected != current_version.version_id)
    {
        return Err(invalid("media artifact version is stale"));
    }
    if inspection.resource.lifecycle == "archived" {
        return Ok(json!({
            "schemaVersion": MEDIA_SCHEMA_VERSION,
            "operation": "media_archive",
            "status": "already_archived",
            "idempotentReplay": true,
            "mediaResourceId": resource_id,
            "mediaVersionId": current_version.version_id,
            "resourceRefs": [version_ref(&inspection.resource, current_version, "media")]
        }));
    }
    let now = operation_at.to_rfc3339();
    let mut record = current.clone();
    record["state"] = json!("archived");
    record["updatedAt"] = json!(now);
    record["archivedAt"] = json!(now);
    record["archive"] = json!({
        "reason": reason,
        "idempotency": idempotency_evidence(invocation, &idempotency_key)
    });
    record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some("archived".to_owned()),
            payload: record,
            state: None,
            locations: current_version.locations.clone(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = "archived".to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    publish_lifecycle_event(
        deps,
        invocation,
        "media.archived",
        &inspection.resource,
        json!({"state": "archived"}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEDIA_SCHEMA_VERSION,
        "operation": "media_archive",
        "status": "archived",
        "idempotentReplay": false,
        "mediaResourceId": resource_id,
        "mediaVersionId": version.version_id,
        "resourceRefs": [version_ref(&inspection.resource, &version, "media")]
    }))
}

struct MediaRecordInput<'a> {
    state: &'a str,
    media_id: &'a str,
    media_kind: MediaKind,
    mime_type: &'a str,
    size_bytes: u64,
    title: Option<&'a str>,
    summary: Option<&'a str>,
    duration_ms: Option<u64>,
    blob_ref: &'a str,
    content_hash: Option<&'a str>,
    scope: &'a EngineResourceScope,
    retention: Value,
    transcription: Value,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    created_at: &'a str,
    updated_at: &'a str,
    archived_at: Option<&'a str>,
    archive_reason: Option<&'a str>,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn media_record(input: MediaRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": MEDIA_SCHEMA_VERSION,
        "state": input.state,
        "mediaId": input.media_id,
        "mediaKind": input.media_kind.as_str(),
        "mimeType": input.mime_type,
        "sizeBytes": input.size_bytes,
        "storage": {
            "blobRef": input.blob_ref,
            "storageClass": "blob_ref",
            "rawBytesStoredInResource": false,
            "providerVisibleRawAudio": false
        },
        "scope": scope_ref(input.scope),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "archivedAt": input.archived_at,
        "retention": input.retention,
        "transcription": input.transcription,
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
    if let Some(title) = input.title {
        record["title"] = json!(title);
    }
    if let Some(summary) = input.summary {
        record["summary"] = json!(summary);
    }
    if let Some(duration_ms) = input.duration_ms {
        record["durationMs"] = json!(duration_ms);
    }
    if let Some(content_hash) = input.content_hash {
        record["storage"]["contentHash"] = json!(content_hash);
    }
    if let Some(reason) = input.archive_reason {
        record["archive"] = json!({"reason": reason});
    }
    record
}

fn transcription_record(payload: &Value) -> Result<Value, CapabilityError> {
    let state = optional_string(payload, "transcriptionState")?
        .map(|value| bounded_token("transcriptionState", &value, 64))
        .transpose()?
        .unwrap_or_else(|| "not_requested".to_owned());
    if !matches!(
        state.as_str(),
        "not_requested" | "local_completed" | "local_failed"
    ) {
        return Err(invalid(
            "transcriptionState must be not_requested, local_completed, or local_failed",
        ));
    }
    let text = optional_string(payload, "transcriptionText")?
        .map(|value| bounded_text("transcriptionText", &value, TRANSCRIPT_MAX_BYTES))
        .transpose()?;
    let language = optional_string(payload, "transcriptionLanguage")?
        .map(|value| bounded_token("transcriptionLanguage", &value, 32))
        .transpose()?;
    let model = optional_string(payload, "transcriptionModel")?
        .map(|value| bounded_token("transcriptionModel", &value, 128))
        .transpose()?;
    Ok(json!({
        "state": state,
        "source": if text.is_some() { "local_composer_transcription" } else { "none" },
        "text": text,
        "language": language,
        "model": model,
        "serverTranscriptionRequested": false,
        "providerVisibleRawAudio": false,
        "rawAudioProviderBoundary": "not_sent"
    }))
}

async fn media_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created media resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "media_create projection")?;
    Ok(media_summary(&inspection.resource, version, payload))
}

fn ensure_media(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != MEDIA_ARTIFACT_KIND {
        return Err(invalid(format!(
            "{operation} expected {MEDIA_ARTIFACT_KIND}"
        )));
    }
    if inspection.resource.schema_id != MEDIA_ARTIFACT_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {MEDIA_ARTIFACT_SCHEMA_ID}"
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
            "{operation} cannot access media outside the current scope"
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

fn validate_media_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{MEDIA_ARTIFACT_KIND}:")) {
        return Err(invalid("mediaResourceId has unsupported resource kind"));
    }
    bounded_token("mediaResourceId", value, 256).map(|_| ())
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
            topic: MEDIA_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "mediaBoundary": {
                    "rawAudioReturned": false,
                    "providerVisibleRawAudio": false,
                    "serverTranscriptionRequested": false
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

fn media_resource_id(scope: &EngineResourceScope, media_id: &str, idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(media_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{MEDIA_ARTIFACT_KIND}:{}", hex::encode(hasher.finalize()))
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
        "kind": MEDIA_ARTIFACT_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresBlobRefsOnly": true,
        "providerVisibleRawAudio": false,
        "serverTranscription": "not_requested"
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [MEDIA_ARTIFACT_KIND],
        "wildcardGrantsAllowed": false,
        "rawAudioProviderAuthorization": "not_authorized"
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

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
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

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
