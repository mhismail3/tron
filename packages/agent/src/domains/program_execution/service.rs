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
    PROGRAM_EXECUTION_LIFECYCLE_TOPIC, PROGRAM_EXECUTION_SCHEMA_VERSION, READ_SCOPE,
    RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_program_execution, program_execution_summary};
use super::validation::*;
use super::{Deps, PROGRAM_EXECUTION_KIND, PROGRAM_EXECUTION_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.program_execution.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.program_execution.idempotency.v1\0";

pub(crate) async fn record_program_execution_record_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_raw_program_execution_fields(payload)?;
    ensure_write_authority(deps, invocation, "program_execution_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let program_id = optional_string(payload, "programId")?
        .map(|value| bounded_token("programId", &value, PROGRAM_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let runtime_id = bounded_token(
        "runtimeId",
        &required_string(payload, "runtimeId")?,
        TOKEN_MAX_BYTES,
    )?;
    let language_id = bounded_token(
        "languageId",
        &required_string(payload, "languageId")?,
        TOKEN_MAX_BYTES,
    )?;
    let program_fingerprint = bounded_token(
        "programFingerprint",
        &required_string(payload, "programFingerprint")?,
        TOKEN_MAX_BYTES,
    )?;
    let source_ref = optional_ref(payload, "sourceRef")?;
    let input_ref = optional_ref(payload, "inputRef")?;
    let output_ref = optional_ref(payload, "outputRef")?;
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
    let resource_limits = resource_limit_policy(payload)?;
    let io_envelope = io_envelope(payload)?;
    let program_label = optional_string(payload, "programLabel")?
        .map(|value| bounded_text("programLabel", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let program_summary = optional_string(payload, "programSummary")?
        .map(|value| bounded_text("programSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = program_execution_resource_id(&scope, &program_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_program_execution(&existing, "program_execution_record replay")?;
        ensure_scope(&existing, &scope, "program_execution_record replay")?;
        let (version, payload) = current_payload(&existing, "program_execution_record replay")?;
        return Ok(json!({
            "schemaVersion": PROGRAM_EXECUTION_SCHEMA_VERSION,
            "operation": "program_execution_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "programExecutionResourceId": resource_id,
            "programExecutionVersionId": version.version_id,
            "record": program_execution_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "program_execution")]
        }));
    }

    let record = program_execution_record(ProgramExecutionRecordInput {
        program_id: &program_id,
        scope: &scope,
        runtime_id: &runtime_id,
        language_id: &language_id,
        program_fingerprint: &program_fingerprint,
        source_ref,
        input_ref,
        output_ref,
        resource_limits,
        io_envelope,
        source_refs,
        evidence_refs,
        program_label: program_label.as_deref(),
        program_summary: program_summary.as_deref(),
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
            kind: PROGRAM_EXECUTION_KIND.to_owned(),
            schema_id: Some(PROGRAM_EXECUTION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "program_execution_record".to_owned(),
                uri: format!("program-execution:{program_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("program execution resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "program_execution.recorded",
        &resource,
        json!({
            "contentFreeProgramExecution": true,
            "runtimeExecutionPerformed": false,
            "rawCodeStored": false,
            "rawIoStored": false,
            "processLaunched": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": PROGRAM_EXECUTION_SCHEMA_VERSION,
        "operation": "program_execution_record",
        "status": "active",
        "idempotentReplay": false,
        "programExecutionResourceId": resource.resource_id,
        "programExecutionVersionId": version_id,
        "record": program_execution_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "program_execution")]
    }))
}

pub(crate) async fn list_program_execution_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "program_execution_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let runtime_id = optional_string(payload, "runtimeId")?
        .map(|value| bounded_token("runtimeId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let language_id = optional_string(payload, "languageId")?
        .map(|value| bounded_token("languageId", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(PROGRAM_EXECUTION_KIND.to_owned()),
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
        ensure_program_execution(&inspection, "program_execution_list")?;
        ensure_scope(&inspection, &scope, "program_execution_list")?;
        let (version, payload) = current_payload(&inspection, "program_execution_list")?;
        if field_mismatch(payload, "runtimeId", runtime_id.as_deref())
            || field_mismatch(payload, "languageId", language_id.as_deref())
        {
            continue;
        }
        records.push(program_execution_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": PROGRAM_EXECUTION_SCHEMA_VERSION,
        "operation": "program_execution_list",
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

pub(crate) async fn inspect_program_execution_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _grant = inspect_read_grant(deps, invocation, "program_execution_inspect").await?;
    let resource_id = required_string(payload, "programExecutionResourceId")?;
    validate_program_execution_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing program execution record {resource_id}")))?;
    ensure_program_execution(&inspection, "program_execution_inspect")?;
    ensure_scope(&inspection, &scope, "program_execution_inspect")?;
    let (version, payload) = current_payload(&inspection, "program_execution_inspect")?;
    Ok(json!({
        "schemaVersion": PROGRAM_EXECUTION_SCHEMA_VERSION,
        "operation": "program_execution_inspect",
        "scope": scope_ref(&scope),
        "record": inspected_program_execution(&inspection.resource, version, payload)
    }))
}

struct ProgramExecutionRecordInput<'a> {
    program_id: &'a str,
    scope: &'a EngineResourceScope,
    runtime_id: &'a str,
    language_id: &'a str,
    program_fingerprint: &'a str,
    source_ref: Option<Value>,
    input_ref: Option<Value>,
    output_ref: Option<Value>,
    resource_limits: Value,
    io_envelope: Value,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    program_label: Option<&'a str>,
    program_summary: Option<&'a str>,
    created_at: &'a str,
    updated_at: &'a str,
    retention: Value,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn program_execution_record(input: ProgramExecutionRecordInput<'_>) -> Value {
    let mut record = json!({
        "schemaVersion": PROGRAM_EXECUTION_SCHEMA_VERSION,
        "state": "active",
        "programId": input.program_id,
        "scope": scope_ref(input.scope),
        "runtimeId": input.runtime_id,
        "languageId": input.language_id,
        "programFingerprint": input.program_fingerprint,
        "resourceLimits": input.resource_limits,
        "ioEnvelope": input.io_envelope,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "retention": input.retention,
        "metadata": {
            "contentFreeProgramExecution": true,
            "runtimeExecutionPerformed": false,
            "processLaunched": false,
            "subprocessLaunched": false,
            "networkAccessPerformed": false,
            "fileWritesPerformed": false,
            "rawCodeStored": false,
            "rawIoStored": false,
            "rawStdoutStored": false,
            "rawStderrStored": false,
            "packageInstallPerformed": false
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
    if let Some(source_ref) = input.source_ref {
        record["sourceRef"] = source_ref;
    }
    if let Some(input_ref) = input.input_ref {
        record["inputRef"] = input_ref;
    }
    if let Some(output_ref) = input.output_ref {
        record["outputRef"] = output_ref;
    }
    if let Some(program_label) = input.program_label {
        record["metadata"]["programLabel"] = json!(program_label);
    }
    if let Some(program_summary) = input.program_summary {
        record["metadata"]["programSummary"] = json!(program_summary);
    }
    record
}

async fn program_execution_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created program execution resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "program_execution_record projection")?;
    Ok(program_execution_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_program_execution(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != PROGRAM_EXECUTION_KIND {
        return Err(invalid(format!(
            "{operation} expected {PROGRAM_EXECUTION_KIND}"
        )));
    }
    if inspection.resource.schema_id != PROGRAM_EXECUTION_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {PROGRAM_EXECUTION_SCHEMA_ID}"
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
            "{operation} cannot access program execution outside the current scope"
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

fn validate_program_execution_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{PROGRAM_EXECUTION_KIND}:")) {
        return Err(invalid(
            "programExecutionResourceId has unsupported resource kind",
        ));
    }
    bounded_token("programExecutionResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
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
            topic: PROGRAM_EXECUTION_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "programExecutionBoundary": {
                    "contentFreeProgramExecution": true,
                    "runtimeExecutionPerformed": false,
                    "processLaunched": false,
                    "rawCodeStored": false,
                    "rawIoStored": false,
                    "fileWritesPerformed": false,
                    "networkAccessPerformed": false
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

fn program_execution_resource_id(
    scope: &EngineResourceScope,
    program_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(program_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!(
        "{PROGRAM_EXECUTION_KIND}:{}",
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
        "kind": PROGRAM_EXECUTION_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "payloadStoresProgramExecutionMetadataOnly": true,
        "contentFreeProgramExecution": true,
        "runtimeExecutionPerformed": false,
        "processLaunched": false,
        "rawCodeStored": false,
        "rawIoStored": false,
        "fileWritesPerformed": false,
        "networkAccessPerformed": false
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [PROGRAM_EXECUTION_KIND],
        "wildcardGrantsAllowed": false,
        "contentFreeProgramExecution": true,
        "runtimeExecutionPerformed": false,
        "processLaunched": false
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
