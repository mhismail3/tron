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
    READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, UPDATE_DIAGNOSTICS_LIFECYCLE_TOPIC,
    UPDATE_DIAGNOSTICS_SCHEMA_VERSION, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_update_diagnostic, update_diagnostic_summary};
use super::validation::*;
use super::{Deps, UPDATE_DIAGNOSTIC_RECORD_KIND, UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.update_diagnostics.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.update_diagnostics.idempotency.v1\0";

pub(crate) async fn record_update_diagnostic_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_update_fields(payload)?;
    ensure_write_authority(deps, invocation, "update_diagnostic_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let diagnostic_id = optional_string(payload, "diagnosticId")?
        .map(|value| bounded_token("diagnosticId", &value, DIAGNOSTIC_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let check_kind = parse_check_kind(optional_string(payload, "checkKind")?)?;
    let release_channel = parse_release_channel(optional_string(payload, "releaseChannel")?)?;
    let release_version = bounded_token(
        "releaseVersion",
        &required_string(payload, "releaseVersion")?,
        TOKEN_MAX_BYTES,
    )?;
    let release_build = optional_string(payload, "releaseBuild")?
        .map(|value| bounded_token("releaseBuild", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let diagnostic_status = parse_diagnostic_status(optional_string(payload, "diagnosticStatus")?)?;
    let signature_status = parse_signature_status(optional_string(payload, "signatureStatus")?)?;
    let diagnostic_label = optional_string(payload, "diagnosticLabel")?
        .map(|value| bounded_text("diagnosticLabel", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let diagnostic_summary = optional_string(payload, "diagnosticSummary")?
        .map(|value| bounded_text("diagnosticSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let provenance_summary = optional_string(payload, "provenanceSummary")?
        .map(|value| bounded_text("provenanceSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    let provenance_refs = optional_array(payload, "provenanceRefs")?.unwrap_or_default();
    let signature_refs = optional_array(payload, "signatureRefs")?.unwrap_or_default();
    validate_ref_array("sourceRefs", &source_refs, MAX_SUPPORT_REFS)?;
    validate_ref_array("evidenceRefs", &evidence_refs, MAX_SUPPORT_REFS)?;
    validate_ref_array("provenanceRefs", &provenance_refs, MAX_SUPPORT_REFS)?;
    validate_ref_array("signatureRefs", &signature_refs, MAX_SUPPORT_REFS)?;
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = update_diagnostic_resource_id(&scope, &diagnostic_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_update_diagnostic(&existing, "update_diagnostic_record replay")?;
        ensure_scope(&existing, &scope, "update_diagnostic_record replay")?;
        let (version, payload) = current_payload(&existing, "update_diagnostic_record replay")?;
        return Ok(json!({
            "schemaVersion": UPDATE_DIAGNOSTICS_SCHEMA_VERSION,
            "operation": "update_diagnostic_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "updateDiagnosticResourceId": resource_id,
            "updateDiagnosticVersionId": version.version_id,
            "record": update_diagnostic_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "update_diagnostic")]
        }));
    }

    let record = update_diagnostic_record(UpdateDiagnosticRecordInput {
        diagnostic_id: &diagnostic_id,
        check_kind: &check_kind,
        scope: &scope,
        release_channel: &release_channel,
        release_version: &release_version,
        release_build: release_build.as_deref(),
        diagnostic_status: &diagnostic_status,
        signature_status: &signature_status,
        source_refs,
        evidence_refs,
        provenance_refs,
        signature_refs,
        diagnostic_label: diagnostic_label.as_deref(),
        diagnostic_summary: diagnostic_summary.as_deref(),
        provenance_summary: provenance_summary.as_deref(),
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
            kind: UPDATE_DIAGNOSTIC_RECORD_KIND.to_owned(),
            schema_id: Some(UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "update_diagnostic_metadata".to_owned(),
                uri: format!("update-diagnostic:{diagnostic_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("update diagnostic resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "update_diagnostics.recorded",
        &resource,
        json!({
            "checkKind": check_kind,
            "releaseChannel": release_channel,
            "diagnosticStatus": diagnostic_status,
            "signatureStatus": signature_status,
            "signedReleaseMetadataOnly": true,
            "liveNetworkCheckPerformed": false,
            "deployAutomationStored": false,
            "packageBytesStored": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": UPDATE_DIAGNOSTICS_SCHEMA_VERSION,
        "operation": "update_diagnostic_record",
        "status": "active",
        "idempotentReplay": false,
        "updateDiagnosticResourceId": resource.resource_id,
        "updateDiagnosticVersionId": version_id,
        "record": update_diagnostic_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "update_diagnostic")]
    }))
}

pub(crate) async fn list_update_diagnostics_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "update_diagnostic_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let release_channel = optional_string(payload, "releaseChannel")?;
    let diagnostic_status = optional_string(payload, "diagnosticStatus")?;
    let signature_status = optional_string(payload, "signatureStatus")?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(UPDATE_DIAGNOSTIC_RECORD_KIND.to_owned()),
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
        ensure_update_diagnostic(&inspection, "update_diagnostic_list")?;
        ensure_scope(&inspection, &scope, "update_diagnostic_list")?;
        let (version, payload) = current_payload(&inspection, "update_diagnostic_list")?;
        if release_channel.as_deref().is_some_and(|value| {
            release_field(payload, "channel").is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        if diagnostic_status.as_deref().is_some_and(|value| {
            release_field(payload, "diagnosticStatus").is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        if signature_status.as_deref().is_some_and(|value| {
            release_field(payload, "signatureStatus").is_some_and(|actual| actual != value)
        }) {
            continue;
        }
        records.push(update_diagnostic_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": UPDATE_DIAGNOSTICS_SCHEMA_VERSION,
        "operation": "update_diagnostic_list",
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

pub(crate) async fn inspect_update_diagnostics_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "update_diagnostic_inspect").await?;
    let resource_id = required_string(payload, "updateDiagnosticResourceId")?;
    validate_update_diagnostic_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing update diagnostic record {resource_id}")))?;
    ensure_update_diagnostic(&inspection, "update_diagnostic_inspect")?;
    ensure_scope(&inspection, &scope, "update_diagnostic_inspect")?;
    let (version, payload) = current_payload(&inspection, "update_diagnostic_inspect")?;
    Ok(json!({
        "schemaVersion": UPDATE_DIAGNOSTICS_SCHEMA_VERSION,
        "operation": "update_diagnostic_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_update_diagnostic(&inspection.resource, version, payload)
    }))
}

struct UpdateDiagnosticRecordInput<'a> {
    diagnostic_id: &'a str,
    check_kind: &'a str,
    scope: &'a EngineResourceScope,
    release_channel: &'a str,
    release_version: &'a str,
    release_build: Option<&'a str>,
    diagnostic_status: &'a str,
    signature_status: &'a str,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    provenance_refs: Vec<Value>,
    signature_refs: Vec<Value>,
    diagnostic_label: Option<&'a str>,
    diagnostic_summary: Option<&'a str>,
    provenance_summary: Option<&'a str>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn update_diagnostic_record(input: UpdateDiagnosticRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": UPDATE_DIAGNOSTICS_SCHEMA_VERSION,
        "state": "active",
        "diagnosticId": input.diagnostic_id,
        "checkKind": input.check_kind,
        "scope": scope_ref(input.scope),
        "release": {
            "channel": input.release_channel,
            "version": input.release_version,
            "diagnosticStatus": input.diagnostic_status,
            "signatureStatus": input.signature_status
        },
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "signedReleaseMetadataOnly": true,
            "liveNetworkCheckPerformed": false,
            "productionEndpointStored": false,
            "packageBytesStored": false,
            "installerExecutionAllowed": false,
            "restartExecutionAllowed": false,
            "deployAutomationStored": false,
            "nativeUiRequired": false
        },
        "refs": {
            "source": input.source_refs,
            "evidence": input.evidence_refs,
            "provenance": input.provenance_refs,
            "signature": input.signature_refs
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(input.invocation),
        "idempotency": idempotency_evidence(input.invocation, input.idempotency_key),
        "revision": input.revision
    });
    if let Some(release_build) = input.release_build {
        record["release"]["build"] = json!(release_build);
    }
    if let Some(diagnostic_label) = input.diagnostic_label {
        record["metadata"]["diagnosticLabel"] = json!(diagnostic_label);
    }
    if let Some(diagnostic_summary) = input.diagnostic_summary {
        record["metadata"]["diagnosticSummary"] = json!(diagnostic_summary);
    }
    if let Some(provenance_summary) = input.provenance_summary {
        record["metadata"]["provenanceSummary"] = json!(provenance_summary);
    }
    record
}

async fn update_diagnostic_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created update diagnostic resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "update_diagnostic_record projection")?;
    Ok(update_diagnostic_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_update_diagnostic(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != UPDATE_DIAGNOSTIC_RECORD_KIND {
        return Err(invalid(format!(
            "{operation} expected {UPDATE_DIAGNOSTIC_RECORD_KIND}"
        )));
    }
    if inspection.resource.schema_id != UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID}"
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
            "{operation} cannot access update diagnostics outside the current scope"
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

fn validate_update_diagnostic_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{UPDATE_DIAGNOSTIC_RECORD_KIND}:")) {
        return Err(invalid(
            "updateDiagnosticResourceId has unsupported resource kind",
        ));
    }
    bounded_token("updateDiagnosticResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
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
            topic: UPDATE_DIAGNOSTICS_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "updateBoundary": {
                    "signedReleaseMetadataOnly": true,
                    "liveNetworkCheckPerformed": false,
                    "installOrRestartExecuted": false,
                    "deployAutomationStored": false,
                    "packageBytesStored": false
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

fn update_diagnostic_resource_id(
    scope: &EngineResourceScope,
    diagnostic_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(diagnostic_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!(
        "{UPDATE_DIAGNOSTIC_RECORD_KIND}:{}",
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
        "kind": UPDATE_DIAGNOSTIC_RECORD_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresSignedReleaseMetadataOnly": true,
        "liveNetworkCheckPerformed": false,
        "installOrRestartExecuted": false,
        "deployAutomationStored": false,
        "packageBytesStored": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [UPDATE_DIAGNOSTIC_RECORD_KIND],
        "wildcardGrantsAllowed": false,
        "networkPolicy": "none"
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

fn release_field<'a>(payload: &'a Value, field: &str) -> Option<&'a str> {
    payload
        .get("release")
        .and_then(|release| release.get(field))
        .and_then(Value::as_str)
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
