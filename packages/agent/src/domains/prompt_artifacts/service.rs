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
    PROMPT_ARTIFACT_LIFECYCLE_TOPIC, PROMPT_ARTIFACT_SCHEMA_VERSION, READ_SCOPE,
    RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_prompt_artifact, prompt_artifact_summary};
use super::validation::*;
use super::{Deps, PROMPT_ARTIFACT_KIND, PROMPT_ARTIFACT_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.prompt_artifact.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.prompt_artifact.idempotency.v1\0";

pub(crate) async fn record_prompt_artifact_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_prompt_artifact_fields(payload)?;
    ensure_write_authority(deps, invocation, "prompt_artifact_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let artifact_id = optional_string(payload, "artifactId")?
        .map(|value| bounded_token("artifactId", &value, ARTIFACT_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let artifact_kind = artifact_kind(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let summary = optional_string(payload, "summary")?
        .map(|value| bounded_text("summary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let preview = optional_string(payload, "preview")?
        .map(|value| bounded_text("preview", &value, PREVIEW_MAX_BYTES))
        .transpose()?;
    let content_fingerprint = bounded_token(
        "contentFingerprint",
        &required_string(payload, "contentFingerprint")?,
        TOKEN_MAX_BYTES,
    )?;
    let content_ref = optional_ref(payload, "contentRef")?;
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_SUPPORT_REFS,
    )?;
    let source_refs = validate_ref_array(
        "sourceRefs",
        &optional_array(payload, "sourceRefs")?.unwrap_or_default(),
        MAX_SUPPORT_REFS,
    )?;
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = prompt_artifact_resource_id(&scope, &artifact_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_prompt_artifact(&existing, "prompt_artifact_record replay")?;
        ensure_scope(&existing, &scope, "prompt_artifact_record replay")?;
        let (version, payload) = current_payload(&existing, "prompt_artifact_record replay")?;
        return Ok(json!({
            "schemaVersion": PROMPT_ARTIFACT_SCHEMA_VERSION,
            "operation": "prompt_artifact_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "promptArtifactResourceId": resource_id,
            "promptArtifactVersionId": version.version_id,
            "record": prompt_artifact_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "prompt_artifact")]
        }));
    }

    let record = prompt_artifact_record(PromptArtifactRecordInput {
        artifact_id: &artifact_id,
        artifact_kind: &artifact_kind,
        scope: &scope,
        title: &title,
        summary: summary.as_deref(),
        preview: preview.as_deref(),
        content_fingerprint: &content_fingerprint,
        content_ref,
        source_refs,
        evidence_refs,
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
            kind: PROMPT_ARTIFACT_KIND.to_owned(),
            schema_id: Some(PROMPT_ARTIFACT_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "prompt_artifact".to_owned(),
                uri: format!("prompt-artifact:{artifact_id}"),
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
        .ok_or_else(|| invalid("prompt artifact resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "prompt_artifact.recorded",
        &resource,
        json!({
            "promptArtifactMetadataOnly": true,
            "explicitOptIn": true,
            "rawPromptStored": false,
            "providerVisibleRawPayloadStored": false,
            "automaticCapturePerformed": false,
            "promptInjectionPerformed": false,
            "promptContextIncluded": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": PROMPT_ARTIFACT_SCHEMA_VERSION,
        "operation": "prompt_artifact_record",
        "status": "active",
        "idempotentReplay": false,
        "promptArtifactResourceId": resource.resource_id,
        "promptArtifactVersionId": version_id,
        "record": prompt_artifact_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "prompt_artifact")]
    }))
}

pub(crate) async fn list_prompt_artifact_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "prompt_artifact_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let artifact_kind = optional_string(payload, "artifactKind")?
        .map(|value| bounded_token("artifactKind", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(PROMPT_ARTIFACT_KIND.to_owned()),
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
        ensure_prompt_artifact(&inspection, "prompt_artifact_list")?;
        ensure_scope(&inspection, &scope, "prompt_artifact_list")?;
        let (version, payload) = current_payload(&inspection, "prompt_artifact_list")?;
        if field_mismatch(payload, "artifactKind", artifact_kind.as_deref()) {
            continue;
        }
        records.push(prompt_artifact_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": PROMPT_ARTIFACT_SCHEMA_VERSION,
        "operation": "prompt_artifact_list",
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

fn field_mismatch(payload: &Value, field: &str, expected: Option<&str>) -> bool {
    expected.is_some_and(|expected| {
        payload
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|actual| actual != expected)
    })
}

pub(crate) async fn inspect_prompt_artifact_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "prompt_artifact_inspect").await?;
    let resource_id = required_string(payload, "promptArtifactResourceId")?;
    validate_prompt_artifact_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing prompt artifact record {resource_id}")))?;
    ensure_prompt_artifact(&inspection, "prompt_artifact_inspect")?;
    ensure_scope(&inspection, &scope, "prompt_artifact_inspect")?;
    let (version, payload) = current_payload(&inspection, "prompt_artifact_inspect")?;
    Ok(json!({
        "schemaVersion": PROMPT_ARTIFACT_SCHEMA_VERSION,
        "operation": "prompt_artifact_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_prompt_artifact(&inspection.resource, version, payload)
    }))
}

struct PromptArtifactRecordInput<'a> {
    artifact_id: &'a str,
    artifact_kind: &'a str,
    scope: &'a EngineResourceScope,
    title: &'a str,
    summary: Option<&'a str>,
    preview: Option<&'a str>,
    content_fingerprint: &'a str,
    content_ref: Option<Value>,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn prompt_artifact_record(input: PromptArtifactRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": PROMPT_ARTIFACT_SCHEMA_VERSION,
        "state": "active",
        "artifactId": input.artifact_id,
        "artifactKind": input.artifact_kind,
        "scope": scope_ref(input.scope),
        "title": input.title,
        "content": {
            "metadataOnly": true,
            "contentFingerprint": input.content_fingerprint,
            "rawPromptStored": false,
            "rawPromptReturned": false,
            "providerVisibleRawPayloadStored": false
        },
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "promptArtifactMetadataOnly": true,
            "explicitOptIn": true,
            "automaticCapturePerformed": false,
            "promptInjectionPerformed": false,
            "promptContextIncluded": false,
            "learnedBehaviorUpdated": false,
            "fileWritesPerformed": false,
            "networkAccessPerformed": false,
            "rawPromptStored": false,
            "providerVisibleRawPayloadStored": false,
            "rawIdempotencyKeyStored": false
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
    if let Some(summary) = input.summary {
        record["summary"] = json!(summary);
    }
    if let Some(preview) = input.preview {
        record["preview"] = json!(preview);
    }
    if let Some(content_ref) = input.content_ref {
        record["content"]["contentRef"] = content_ref;
    }
    record
}

async fn prompt_artifact_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created prompt artifact resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "prompt_artifact_record projection")?;
    Ok(prompt_artifact_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_prompt_artifact(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != PROMPT_ARTIFACT_KIND {
        return Err(invalid(format!(
            "{operation} expected {PROMPT_ARTIFACT_KIND}"
        )));
    }
    if inspection.resource.schema_id != PROMPT_ARTIFACT_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {PROMPT_ARTIFACT_SCHEMA_ID}"
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
            "{operation} cannot access prompt artifact outside the current scope"
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

fn validate_prompt_artifact_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{PROMPT_ARTIFACT_KIND}:")) {
        return Err(invalid(
            "promptArtifactResourceId has unsupported resource kind",
        ));
    }
    bounded_token("promptArtifactResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
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
            topic: PROMPT_ARTIFACT_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "promptArtifactBoundary": {
                    "promptArtifactMetadataOnly": true,
                    "explicitOptIn": true,
                    "rawPromptStored": false,
                    "providerVisibleRawPayloadStored": false,
                    "automaticCapturePerformed": false,
                    "promptInjectionPerformed": false,
                    "promptContextIncluded": false
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

fn prompt_artifact_resource_id(
    scope: &EngineResourceScope,
    artifact_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(artifact_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{PROMPT_ARTIFACT_KIND}:{}", hex::encode(hasher.finalize()))
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
        "kind": PROMPT_ARTIFACT_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresPromptArtifactMetadataOnly": true,
        "explicitOptIn": true,
        "rawPromptStored": false,
        "providerVisibleRawPayloadStored": false,
        "automaticCapturePerformed": false,
        "promptInjectionPerformed": false,
        "promptContextIncluded": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [PROMPT_ARTIFACT_KIND],
        "wildcardGrantsAllowed": false,
        "promptArtifactMetadataOnly": true,
        "rawPromptStored": false,
        "promptInjectionPerformed": false
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
