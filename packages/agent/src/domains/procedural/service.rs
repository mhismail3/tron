//! Resource-backed procedural state record/list/inspect and activation review behavior.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    ActorKind, CreateResource, EngineGrant, EngineHostHandle, EngineResource,
    EngineResourceInspection, EngineResourceLocation, EngineResourceScope, EngineResourceVersion,
    Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::{
    ACTIVATION_DECISION_SCHEMA_VERSION, ACTIVATION_REQUEST_SCHEMA_VERSION,
    PROCEDURAL_ACTIVATION_DECISION_KIND, PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID,
    PROCEDURAL_ACTIVATION_REQUEST_KIND, PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID,
    PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID, READ_SCOPE, SCHEMA_VERSION, WRITE_SCOPE,
};
use crate::domains::procedural::projection::{
    STRING_PREVIEW_BYTES, detail_projection, is_safe_content_hash, is_safe_projection_scalar,
    safe_metadata_value, summary_projection,
};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const WORKER: &str = "procedural";
const LIST_LIMIT_DEFAULT: usize = 25;
const LIST_LIMIT_MAX: usize = 100;
const INSPECT_ARRAY_ITEMS_DEFAULT: usize = 25;
const INSPECT_ARRAY_ITEMS_MAX: usize = 100;
const MAX_INPUT_STRING_BYTES: usize = 256;
const MAX_SUMMARY_BYTES: usize = 512;
const MAX_REFS: usize = 25;
const SUPPORTED_PROCEDURAL_KINDS: &[&str] = &["skill", "rule", "hook", "procedure"];
const READABLE_LIFECYCLES: &[&str] = &["draft", "candidate", "validated"];

pub(crate) async fn record_procedural_definition_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let operation = "procedural_definition_record";
    ensure_trusted_current_scope(invocation, operation)?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &[PROCEDURAL_RECORD_KIND],
    )?;
    require_read_selectors(&grant, &procedural_kind, operation)?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = record_scope(invocation, payload)?;
    let definition_id = bounded_token(
        "definitionId",
        &optional_string(payload, "definitionId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
    )?;
    let status = optional_string(payload, "status")?.unwrap_or_else(|| "candidate".to_owned());
    ensure_readable_lifecycle(&status, operation)?;
    let summary = bounded_text(
        "summary",
        &required_string(payload, "summary")?,
        MAX_SUMMARY_BYTES,
    )?;
    let resource_id =
        procedural_record_resource_id(&scope, &procedural_kind, &definition_id, &idempotency_key);
    if let Some(existing) = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_procedural_record(&existing, "procedural_definition_record replay")?;
        ensure_scope_matches(&existing, &scope, "procedural_definition_record replay")?;
        let (version, current) = current_payload(&existing, "procedural_definition_record replay")?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": operation,
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "proceduralRecordResourceId": resource_id,
            "proceduralRecordVersionId": version.version_id,
            "record": summary_projection(&existing.resource, version, current),
            "activation": activation_proof(),
            "network": {"performed": false, "requiredPolicy": "none"},
            "redacted": true
        }));
    }
    let now = operation_at.to_rfc3339();
    let record = json!({
        "schemaVersion": SCHEMA_VERSION,
        "proceduralKind": procedural_kind,
        "identity": {
            "id": definition_id,
            "name": optional_bounded_text(payload, "name", MAX_INPUT_STRING_BYTES)?.unwrap_or_else(|| format!("Procedural {procedural_kind}")),
            "version": optional_bounded_text(payload, "definitionVersion", MAX_INPUT_STRING_BYTES)?.unwrap_or_else(|| "0.1.0".to_owned()),
            "namespace": optional_bounded_text(payload, "namespace", MAX_INPUT_STRING_BYTES)?.unwrap_or_else(|| "procedural.local".to_owned())
        },
        "summary": summary,
        "status": status,
        "provenance": safe_input_object(payload.get("provenance"))?,
        "eval": {
            "status": optional_bounded_token(payload, "evalStatus")?.unwrap_or_else(|| "pending_review".to_owned()),
            "profile": optional_bounded_text(payload, "evalProfile", MAX_INPUT_STRING_BYTES)?.unwrap_or_else(|| "metadata_only".to_owned()),
            "lastRunAt": optional_bounded_token(payload, "evalLastRunAt")?.unwrap_or_else(|| now.clone())
        },
        "activation": {
            "available": false,
            "reason": "review_required",
            "requested": false
        },
        "sourceRefs": safe_ref_array(payload, "sourceRefs")?,
        "traceRefs": safe_ref_array(payload, "traceRefs")?,
        "replayRefs": safe_ref_array(payload, "replayRefs")?,
        "validationEvidence": {
            "status": optional_bounded_token(payload, "validationStatus")?.unwrap_or_else(|| "pending_review".to_owned()),
            "evidenceRefs": safe_ref_array(payload, "validationEvidenceRefs")?
        },
        "review": {
            "state": "pending_review",
            "required": true,
            "reviewRefs": safe_ref_array(payload, "reviewRefs")?
        },
        "triggerDeclarations": safe_ref_array(payload, "triggerDeclarations")?,
        "conflictMetadata": safe_input_object(payload.get("conflictMetadata"))?,
        "orderingMetadata": safe_input_object(payload.get("orderingMetadata"))?,
        "scopedAuthorityProof": scoped_authority_proof(payload)?,
        "boundedRefs": safe_ref_array(payload, "boundedRefs")?,
        "idempotency": {
            "algorithm": "sha256:tron.procedural.idempotency.v1",
            "fingerprint": idempotency_fingerprint(&scope, operation, &idempotency_key)
        },
        "providerProjection": provider_projection_proof(),
        "contentHash": optional_content_hash(payload)?,
        "revision": 1
    });
    let resource = host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: PROCEDURAL_RECORD_KIND.to_owned(),
            schema_id: Some(PROCEDURAL_RECORD_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(status),
            policy: resource_policy(PROCEDURAL_RECORD_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "procedural_record".to_owned(),
                uri: format!("procedural-record:{procedural_kind}"),
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
        .ok_or_else(|| invalid("procedural record was created without a current version"))?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "proceduralRecordResourceId": resource.resource_id,
        "proceduralRecordVersionId": version_id,
        "record": summary_for_resource(host, &resource, operation).await?,
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn list_procedural_state_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, "procedural_state_list")?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_read_grant(host, invocation, "procedural_state_list").await?;
    require_read_selectors(&grant, &procedural_kind, "procedural_state_list")?;
    let lifecycle = optional_string(payload, "lifecycle")?;
    if let Some(lifecycle) = &lifecycle {
        validate_token(lifecycle, "lifecycle")?;
        ensure_readable_lifecycle(lifecycle, "procedural_state_list")?;
    }
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let scopes = readable_scopes(invocation);
    let mut resources = Vec::new();
    for scope in &scopes {
        let mut scoped = host
            .list_resources(ListResources {
                kind: Some(PROCEDURAL_RECORD_KIND.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: lifecycle.clone(),
                limit: limit.saturating_add(1),
            })
            .await
            .map_err(engine_error)?;
        resources.append(&mut scoped);
        if resources.len() > limit {
            break;
        }
    }
    let truncated = resources.len() > limit;
    let mut records = Vec::new();
    for resource in resources {
        if records.len() >= limit {
            break;
        }
        let Some(inspection) = host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            return Err(invalid(format!(
                "procedural_state_list missing listed resource {}",
                resource.resource_id
            )));
        };
        ensure_procedural_record(&inspection, "procedural_state_list")?;
        ensure_readable_scope(&inspection, invocation, "procedural_state_list")?;
        let (version, current) = current_payload(&inspection, "procedural_state_list")?;
        if let Some(stored_kind) = current.get("proceduralKind").and_then(Value::as_str)
            && SUPPORTED_PROCEDURAL_KINDS
                .iter()
                .any(|supported| supported == &stored_kind)
            && stored_kind != procedural_kind
        {
            continue;
        }
        validate_record_payload(current, &procedural_kind, "procedural_state_list")?;
        ensure_readable_lifecycle(&inspection.resource.lifecycle, "procedural_state_list")?;
        records.push(summary_projection(&inspection.resource, version, current));
    }

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "procedural_state_list",
        "scope": scope_projection(invocation),
        "proceduralKind": procedural_kind,
        "records": records,
        "limits": {
            "requestedLimit": limit,
            "returned": records.len(),
            "truncated": truncated,
            "supportedProceduralKinds": SUPPORTED_PROCEDURAL_KINDS
        },
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn inspect_procedural_state_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, "procedural_state_inspect")?;
    let resource_id = required_string(payload, "proceduralRecordResourceId")?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_read_grant(host, invocation, "procedural_state_inspect").await?;
    require_read_selectors(&grant, &procedural_kind, "procedural_state_inspect")?;
    require_exact_resource_selector(&grant, &resource_id, "procedural_state_inspect")?;
    let max_items = optional_u64(payload, "maxEvidenceItems")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_ARRAY_ITEMS_DEFAULT)
        .clamp(1, INSPECT_ARRAY_ITEMS_MAX);
    let inspection = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing procedural record {resource_id}")))?;
    ensure_procedural_record(&inspection, "procedural_state_inspect")?;
    ensure_readable_scope(&inspection, invocation, "procedural_state_inspect")?;
    ensure_readable_lifecycle(&inspection.resource.lifecycle, "procedural_state_inspect")?;
    let (version, current) = current_payload(&inspection, "procedural_state_inspect")?;
    validate_record_payload(current, &procedural_kind, "procedural_state_inspect")?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "procedural_state_inspect",
        "scope": scope_projection(invocation),
        "resource": detail_projection(&inspection.resource, version, current, max_items),
        "limits": {"maxEvidenceItems": max_items, "stringPreviewBytes": STRING_PREVIEW_BYTES},
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn record_activation_request_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let operation = "procedural_activation_request_record";
    ensure_trusted_current_scope(invocation, operation)?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &[PROCEDURAL_RECORD_KIND, PROCEDURAL_ACTIVATION_REQUEST_KIND],
    )?;
    require_read_selectors(&grant, &procedural_kind, operation)?;
    let procedural_record_id = required_string(payload, "proceduralRecordResourceId")?;
    require_exact_resource_selector(&grant, &procedural_record_id, operation)?;
    let procedural = inspect_procedural_prerequisite(
        host,
        invocation,
        &procedural_record_id,
        &procedural_kind,
        operation,
    )
    .await?;
    let requested_action = activation_request_action(payload)?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = record_scope(invocation, payload)?;
    ensure_scope_matches(&procedural, &scope, operation)?;
    let request_id = bounded_token(
        "activationRequestId",
        &optional_string(payload, "activationRequestId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
    )?;
    let resource_id = activation_request_resource_id(&scope, &request_id, &idempotency_key);
    if let Some(existing) = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_activation_request(&existing, "procedural_activation_request_record replay")?;
        ensure_scope_matches(
            &existing,
            &scope,
            "procedural_activation_request_record replay",
        )?;
        let (version, current) =
            current_payload(&existing, "procedural_activation_request_record replay")?;
        return Ok(generic_record_result(
            ACTIVATION_REQUEST_SCHEMA_VERSION,
            operation,
            "proceduralActivationRequest",
            "proceduralActivationRequestResourceId",
            "proceduralActivationRequestVersionId",
            &existing.resource,
            version,
            current,
            true,
        ));
    }
    let now = operation_at.to_rfc3339();
    let record = json!({
        "schemaVersion": ACTIVATION_REQUEST_SCHEMA_VERSION,
        "state": "pending_review",
        "requestId": request_id,
        "scope": scope_ref(&scope),
        "proceduralRecord": procedural_ref(&procedural, "procedural_activation_request_record")?,
        "requestedAction": requested_action,
        "review": {
            "state": "pending_review",
            "required": true,
            "reviewRefs": safe_ref_array(payload, "reviewRefs")?
        },
        "validationEvidenceRefs": safe_ref_array(payload, "validationEvidenceRefs")?,
        "triggerDeclarations": safe_ref_array(payload, "triggerDeclarations")?,
        "conflictMetadata": safe_input_object(payload.get("conflictMetadata"))?,
        "orderingMetadata": safe_input_object(payload.get("orderingMetadata"))?,
        "scopedAuthorityProof": scoped_authority_proof(payload)?,
        "rollbackProofRefs": safe_ref_array(payload, "rollbackProofRefs")?,
        "traceRefs": safe_ref_array(payload, "traceRefs")?,
        "replayRefs": safe_ref_array(payload, "replayRefs")?,
        "boundedRefs": safe_ref_array(payload, "boundedRefs")?,
        "idempotency": {
            "algorithm": "sha256:tron.procedural.activation_request.idempotency.v1",
            "fingerprint": idempotency_fingerprint(&scope, operation, &idempotency_key)
        },
        "safetyProof": activation_safety_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: PROCEDURAL_ACTIVATION_REQUEST_KIND.to_owned(),
            schema_id: Some(PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("pending_review".to_owned()),
            policy: resource_policy(PROCEDURAL_ACTIVATION_REQUEST_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "procedural_activation_request".to_owned(),
                uri: "procedural-activation-request:pending-review".to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("procedural activation request was created without a current version")
    })?;
    Ok(json!({
        "schemaVersion": ACTIVATION_REQUEST_SCHEMA_VERSION,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "proceduralActivationRequestResourceId": resource.resource_id,
        "proceduralActivationRequestVersionId": version_id,
        "proceduralActivationRequest": generic_summary_for_resource(host, &resource, operation).await?,
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn list_activation_requests_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_generic_procedural_resources(
        host,
        invocation,
        payload,
        "procedural_activation_request_list",
        PROCEDURAL_ACTIVATION_REQUEST_KIND,
        ACTIVATION_REQUEST_SCHEMA_VERSION,
        "activationRequests",
        Some("pending_review"),
    )
    .await
}

pub(crate) async fn inspect_activation_request_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_generic_procedural_resource(
        host,
        invocation,
        payload,
        "procedural_activation_request_inspect",
        PROCEDURAL_ACTIVATION_REQUEST_KIND,
        PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID,
        ACTIVATION_REQUEST_SCHEMA_VERSION,
        "proceduralActivationRequestResourceId",
        "proceduralActivationRequest",
    )
    .await
}

pub(crate) async fn record_activation_decision_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let operation = "procedural_activation_decision_record";
    ensure_trusted_current_scope(invocation, operation)?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &[
            PROCEDURAL_RECORD_KIND,
            PROCEDURAL_ACTIVATION_REQUEST_KIND,
            PROCEDURAL_ACTIVATION_DECISION_KIND,
        ],
    )?;
    require_read_selectors(&grant, &procedural_kind, operation)?;
    let request_id = required_string(payload, "proceduralActivationRequestResourceId")?;
    require_exact_resource_selector(&grant, &request_id, operation)?;
    let request =
        inspect_activation_request_prerequisite(host, invocation, &request_id, operation).await?;
    let procedural_record_id = request
        .versions
        .iter()
        .find(|version| {
            request
                .resource
                .current_version_id
                .as_ref()
                .is_some_and(|current| current == &version.version_id)
        })
        .and_then(|version| version.payload.pointer("/proceduralRecord/resourceId"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("activation request is missing procedural record ref"))?
        .to_owned();
    require_exact_resource_selector(&grant, &procedural_record_id, operation)?;
    let procedural = inspect_procedural_prerequisite(
        host,
        invocation,
        &procedural_record_id,
        &procedural_kind,
        operation,
    )
    .await?;
    let scope = record_scope(invocation, payload)?;
    ensure_scope_matches(&request, &scope, operation)?;
    ensure_scope_matches(&procedural, &scope, operation)?;
    let decision = activation_decision(payload)?;
    let state = activation_decision_state(&decision);
    let decision_id = bounded_token(
        "activationDecisionId",
        &optional_string(payload, "activationDecisionId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
    )?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        MAX_SUMMARY_BYTES,
    )?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let resource_id = activation_decision_resource_id(&scope, &decision_id, &idempotency_key);
    if let Some(existing) = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_activation_decision(&existing, "procedural_activation_decision_record replay")?;
        ensure_scope_matches(
            &existing,
            &scope,
            "procedural_activation_decision_record replay",
        )?;
        let (version, current) =
            current_payload(&existing, "procedural_activation_decision_record replay")?;
        return Ok(generic_record_result(
            ACTIVATION_DECISION_SCHEMA_VERSION,
            operation,
            "proceduralActivationDecision",
            "proceduralActivationDecisionResourceId",
            "proceduralActivationDecisionVersionId",
            &existing.resource,
            version,
            current,
            true,
        ));
    }
    let now = operation_at.to_rfc3339();
    let record = json!({
        "schemaVersion": ACTIVATION_DECISION_SCHEMA_VERSION,
        "state": state,
        "decisionId": decision_id,
        "scope": scope_ref(&scope),
        "activationRequest": generic_ref(&request, "procedural_activation_request")?,
        "proceduralRecord": procedural_ref(&procedural, operation)?,
        "decision": decision,
        "decisionReason": reason,
        "activationResult": {
            "performed": false,
            "triggerRegistered": false,
            "hookFired": false,
            "promptInjected": false,
            "procedureExecuted": false,
            "deactivationRecorded": matches!(state, "deactivated"),
            "rollbackProofRequired": matches!(state, "rollback_required")
        },
        "rollbackProofRefs": safe_ref_array(payload, "rollbackProofRefs")?,
        "deactivationProofRefs": safe_ref_array(payload, "deactivationProofRefs")?,
        "traceRefs": safe_ref_array(payload, "traceRefs")?,
        "replayRefs": safe_ref_array(payload, "replayRefs")?,
        "boundedRefs": safe_ref_array(payload, "boundedRefs")?,
        "idempotency": {
            "algorithm": "sha256:tron.procedural.activation_decision.idempotency.v1",
            "fingerprint": idempotency_fingerprint(&scope, operation, &idempotency_key)
        },
        "safetyProof": activation_safety_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: PROCEDURAL_ACTIVATION_DECISION_KIND.to_owned(),
            schema_id: Some(PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.to_owned()),
            policy: resource_policy(PROCEDURAL_ACTIVATION_DECISION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "procedural_activation_decision".to_owned(),
                uri: "procedural-activation-decision:metadata-only".to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("procedural activation decision was created without a current version")
    })?;
    Ok(json!({
        "schemaVersion": ACTIVATION_DECISION_SCHEMA_VERSION,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "proceduralActivationDecisionResourceId": resource.resource_id,
        "proceduralActivationDecisionVersionId": version_id,
        "proceduralActivationDecision": generic_summary_for_resource(host, &resource, operation).await?,
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn list_activation_decisions_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_generic_procedural_resources(
        host,
        invocation,
        payload,
        "procedural_activation_decision_list",
        PROCEDURAL_ACTIVATION_DECISION_KIND,
        ACTIVATION_DECISION_SCHEMA_VERSION,
        "activationDecisions",
        None,
    )
    .await
}

pub(crate) async fn inspect_activation_decision_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_generic_procedural_resource(
        host,
        invocation,
        payload,
        "procedural_activation_decision_inspect",
        PROCEDURAL_ACTIVATION_DECISION_KIND,
        PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID,
        ACTIVATION_DECISION_SCHEMA_VERSION,
        "proceduralActivationDecisionResourceId",
        "proceduralActivationDecision",
    )
    .await
}

async fn inspect_read_grant(
    host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[PROCEDURAL_RECORD_KIND],
    )?;
    Ok(grant)
}

async fn inspect_grant(
    host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_grant_items(
    grant: &EngineGrant,
    operation: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
) -> Result<(), CapabilityError> {
    for scope in scopes {
        require_explicit_grant_item(&grant.allowed_authority_scopes, scope, operation)?;
    }
    for kind in resource_kinds {
        require_explicit_grant_item(&grant.allowed_resource_kinds, kind, operation)?;
    }
    Ok(())
}

fn require_read_selectors(
    grant: &EngineGrant,
    procedural_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if grant
        .resource_selectors
        .iter()
        .any(|selector| selector == "*")
    {
        return Err(invalid(format!(
            "{operation} requires explicit resource selectors; wildcard grants are not accepted"
        )));
    }
    for required in [
        format!("kind:{PROCEDURAL_RECORD_KIND}"),
        format!("proceduralKind:{procedural_kind}"),
    ] {
        if !grant
            .resource_selectors
            .iter()
            .any(|selector| selector == &required)
        {
            return Err(invalid(format!(
                "{operation} requires an explicit {required} selector"
            )));
        }
    }
    Ok(())
}

fn require_exact_resource_selector(
    grant: &EngineGrant,
    resource_id: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let selector = format!("resource:{resource_id}");
    if grant
        .resource_selectors
        .iter()
        .any(|actual| actual == resource_id || actual == &selector)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires exact selector for resource {resource_id}"
        )))
    }
}

fn require_explicit_grant_item(
    items: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if items.iter().any(|item| item == "*") {
        return Err(invalid(format!(
            "{operation} requires explicit authority; wildcard grants are not accepted"
        )));
    }
    if items.iter().any(|item| item == required) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires {required} authority"
        )))
    }
}

fn ensure_trusted_current_scope(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .ok_or_else(|| {
            invalid(format!(
                "{operation} requires trusted current session context"
            ))
        })?;
    if invocation.causal_context.workspace_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current workspace context"
        )));
    }
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let expected = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected {
                return Err(invalid(format!(
                    "{operation} agent actor must match the current session"
                )));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(format!(
                "{operation} requires trusted agent or system context"
            )));
        }
    }
    Ok(())
}

fn ensure_procedural_record(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != PROCEDURAL_RECORD_KIND {
        return Err(invalid(format!(
            "{operation} expected {PROCEDURAL_RECORD_KIND}"
        )));
    }
    if inspection.resource.schema_id.as_str() != PROCEDURAL_RECORD_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {PROCEDURAL_RECORD_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_readable_scope(
    inspection: &EngineResourceInspection,
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    match &inspection.resource.scope {
        EngineResourceScope::Session(session)
            if invocation.causal_context.session_id.as_ref() == Some(session) =>
        {
            Ok(())
        }
        EngineResourceScope::Workspace(workspace)
            if invocation.causal_context.workspace_id.as_ref() == Some(workspace) =>
        {
            Ok(())
        }
        _ => Err(invalid(format!(
            "{operation} cannot inspect procedural records outside the current session/workspace scope"
        ))),
    }
}

fn readable_scopes(invocation: &Invocation) -> Vec<EngineResourceScope> {
    let mut scopes = Vec::new();
    if let Some(session) = &invocation.causal_context.session_id {
        scopes.push(EngineResourceScope::Session(session.clone()));
    }
    if let Some(workspace) = &invocation.causal_context.workspace_id {
        scopes.push(EngineResourceScope::Workspace(workspace.clone()));
    }
    scopes
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
    if !version.state.may_be_current() {
        return Err(invalid(format!(
            "{operation} current version is not available"
        )));
    }
    Ok((version, &version.payload))
}

fn validate_record_payload(
    payload: &Value,
    expected_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let object = payload
        .as_object()
        .ok_or_else(|| invalid(format!("{operation} procedural payload must be an object")))?;
    for required in [
        "schemaVersion",
        "proceduralKind",
        "identity",
        "summary",
        "status",
        "provenance",
        "eval",
        "activation",
        "sourceRefs",
        "traceRefs",
        "replayRefs",
        "revision",
    ] {
        if !object.contains_key(required) {
            return Err(invalid(format!(
                "{operation} malformed procedural payload missing {required}"
            )));
        }
    }
    if payload.get("schemaVersion").and_then(Value::as_str) != Some(SCHEMA_VERSION) {
        return Err(invalid(format!(
            "{operation} expected payload schemaVersion {SCHEMA_VERSION}"
        )));
    }
    if payload.get("proceduralKind").and_then(Value::as_str) != Some(expected_kind) {
        return Err(invalid(format!(
            "{operation} procedural kind mismatch for {expected_kind}"
        )));
    }
    if !matches!(payload.get("identity"), Some(Value::Object(_))) {
        return Err(invalid(format!(
            "{operation} procedural identity must be an object"
        )));
    }
    for field in ["provenance", "eval", "activation"] {
        if !matches!(payload.get(field), Some(Value::Object(_))) {
            return Err(invalid(format!(
                "{operation} procedural {field} must be an object"
            )));
        }
    }
    for field in ["sourceRefs", "traceRefs", "replayRefs"] {
        if !matches!(payload.get(field), Some(Value::Array(_))) {
            return Err(invalid(format!(
                "{operation} procedural {field} must be an array"
            )));
        }
    }
    let status = payload
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{operation} procedural status must be a string")))?;
    ensure_readable_lifecycle(status, operation)?;
    validate_eval_projection_fields(payload, operation)?;
    validate_content_hash(payload, operation)?;
    Ok(())
}

fn validate_eval_projection_fields(
    payload: &Value,
    operation: &str,
) -> Result<(), CapabilityError> {
    let eval = payload
        .get("eval")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid(format!("{operation} procedural eval must be an object")))?;
    validate_optional_safe_scalar(eval.get("status"), "eval.status", operation)?;
    if let Some(last_run_at) =
        validate_optional_safe_scalar(eval.get("lastRunAt"), "eval.lastRunAt", operation)?
    {
        chrono::DateTime::parse_from_rfc3339(last_run_at).map_err(|_| {
            invalid(format!(
                "{operation} procedural eval.lastRunAt must be an RFC3339 timestamp"
            ))
        })?;
    }
    Ok(())
}

fn validate_optional_safe_scalar<'a>(
    value: Option<&'a Value>,
    field: &str,
    operation: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if is_safe_projection_scalar(text) => Ok(Some(text.as_str())),
        Some(Value::String(_)) => Err(invalid(format!(
            "{operation} procedural {field} must be a bounded safe scalar string"
        ))),
        Some(_) => Err(invalid(format!(
            "{operation} procedural {field} must be a string"
        ))),
    }
}

fn validate_content_hash(payload: &Value, operation: &str) -> Result<(), CapabilityError> {
    match payload.get("contentHash") {
        None | Some(Value::Null) => Ok(()),
        Some(Value::String(text)) if is_safe_content_hash(text) => Ok(()),
        Some(Value::String(_)) => Err(invalid(format!(
            "{operation} procedural contentHash must be a sha256 content hash"
        ))),
        Some(_) => Err(invalid(format!(
            "{operation} procedural contentHash must be a string"
        ))),
    }
}

fn ensure_readable_lifecycle(lifecycle: &str, operation: &str) -> Result<(), CapabilityError> {
    if READABLE_LIFECYCLES.iter().any(|state| state == &lifecycle) {
        Ok(())
    } else if matches!(lifecycle, "disabled" | "stale" | "archived") {
        Err(invalid(format!(
            "{operation} does not expose {lifecycle} procedural records"
        )))
    } else {
        Err(invalid(format!(
            "{operation} unsupported procedural lifecycle {lifecycle}"
        )))
    }
}

fn scope_projection(invocation: &Invocation) -> Value {
    json!({
        "session": invocation.causal_context.session_id,
        "workspace": invocation.causal_context.workspace_id
    })
}

fn activation_proof() -> Value {
    json!({
        "performed": false,
        "skillActivated": false,
        "ruleApplied": false,
        "hookFired": false,
        "procedureExecuted": false,
        "triggerRegistered": false,
        "promptInjected": false,
        "learnedBehavior": false,
        "autonomousExecution": false,
        "toolExecution": false,
        "workerStarted": false,
        "jobStarted": false,
        "processStarted": false,
        "networkStarted": false,
        "packageInstalled": false,
        "catalogRegistered": false
    })
}

async fn list_generic_procedural_resources(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    kind: &str,
    schema_version: &str,
    array_field: &str,
    default_lifecycle: Option<&str>,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, operation)?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[kind],
    )?;
    require_read_selectors(&grant, &procedural_kind, operation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let lifecycle = optional_string(payload, "lifecycle")?.or_else(|| {
        payload
            .get("includeArchived")
            .and_then(Value::as_bool)
            .is_some_and(|include| include)
            .then(|| "".to_owned())
            .or_else(|| default_lifecycle.map(str::to_owned))
    });
    let mut resources = Vec::new();
    for scope in readable_scopes(invocation) {
        let mut scoped = host
            .list_resources(ListResources {
                kind: Some(kind.to_owned()),
                scope: Some(scope),
                lifecycle: lifecycle
                    .as_ref()
                    .filter(|value| !value.is_empty())
                    .cloned(),
                limit: limit.saturating_add(1),
            })
            .await
            .map_err(engine_error)?;
        resources.append(&mut scoped);
        if resources.len() > limit {
            break;
        }
    }
    let truncated = resources.len() > limit;
    let mut projected = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_kind_schema(&inspection, kind, operation)?;
        ensure_readable_scope(&inspection, invocation, operation)?;
        let (version, current) = current_payload(&inspection, operation)?;
        if current
            .pointer("/proceduralRecord/proceduralKind")
            .and_then(Value::as_str)
            .is_some_and(|stored| stored != procedural_kind)
        {
            continue;
        }
        projected.push(generic_summary(&inspection.resource, version, current));
    }
    let mut result = json!({
        "schemaVersion": schema_version,
        "operation": operation,
        "scope": scope_projection(invocation),
        "proceduralKind": procedural_kind,
        "limits": {
            "requestedLimit": limit,
            "returned": projected.len(),
            "truncated": truncated
        },
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    });
    result[array_field] = Value::Array(projected);
    Ok(result)
}

async fn inspect_generic_procedural_resource(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    kind: &str,
    schema_id: &str,
    schema_version: &str,
    resource_id_field: &str,
    output_field: &str,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, operation)?;
    let procedural_kind = required_procedural_kind(payload)?;
    let resource_id = required_string(payload, resource_id_field)?;
    let grant = inspect_grant(host, invocation, operation).await?;
    require_grant_items(
        &grant,
        operation,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[kind],
    )?;
    require_read_selectors(&grant, &procedural_kind, operation)?;
    require_exact_resource_selector(&grant, &resource_id, operation)?;
    let max_items = optional_u64(payload, "maxEvidenceItems")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_ARRAY_ITEMS_DEFAULT)
        .clamp(1, INSPECT_ARRAY_ITEMS_MAX);
    let inspection = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing procedural resource {resource_id}")))?;
    if inspection.resource.kind != kind || inspection.resource.schema_id != schema_id {
        return Err(invalid(format!(
            "{operation} expected {kind} with schema {schema_id}"
        )));
    }
    ensure_readable_scope(&inspection, invocation, operation)?;
    let (version, current) = current_payload(&inspection, operation)?;
    if current
        .pointer("/proceduralRecord/proceduralKind")
        .and_then(Value::as_str)
        .is_some_and(|stored| stored != procedural_kind)
    {
        return Err(invalid(format!(
            "{operation} procedural kind mismatch for {procedural_kind}"
        )));
    }
    Ok(json!({
        "schemaVersion": schema_version,
        "operation": operation,
        "scope": scope_projection(invocation),
        output_field: generic_detail(&inspection.resource, version, current, max_items),
        "limits": {"maxEvidenceItems": max_items, "stringPreviewBytes": STRING_PREVIEW_BYTES},
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

fn generic_record_result(
    schema_version: &str,
    operation: &str,
    output_field: &str,
    resource_id_field: &str,
    version_id_field: &str,
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    idempotent_replay: bool,
) -> Value {
    json!({
        "schemaVersion": schema_version,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": idempotent_replay,
        resource_id_field: resource.resource_id,
        version_id_field: version.version_id,
        output_field: generic_summary(resource, version, payload),
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    })
}

async fn summary_for_resource(
    host: &EngineHostHandle,
    resource: &EngineResource,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let inspection = host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} created resource cannot be inspected")))?;
    let (version, current) = current_payload(&inspection, operation)?;
    Ok(summary_projection(&inspection.resource, version, current))
}

async fn generic_summary_for_resource(
    host: &EngineHostHandle,
    resource: &EngineResource,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let inspection = host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} created resource cannot be inspected")))?;
    let (version, current) = current_payload(&inspection, operation)?;
    Ok(generic_summary(&inspection.resource, version, current))
}

fn generic_summary(
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
        "state": payload.get("state").cloned().unwrap_or(Value::Null),
        "proceduralRecord": safe_metadata_value(payload.get("proceduralRecord").unwrap_or(&Value::Null), 4, 0),
        "requestedAction": payload.get("requestedAction").cloned().unwrap_or(Value::Null),
        "decision": payload.get("decision").cloned().unwrap_or(Value::Null),
        "resourceRefs": [resource_version_ref(resource, version, &resource.kind)]
    })
}

fn generic_detail(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    max_items: usize,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payload": safe_metadata_value(payload, max_items, 0),
        "resourceRefs": [resource_version_ref(resource, version, &resource.kind)],
        "redaction": {
            "rawBody": true,
            "rawManifest": true,
            "commands": true,
            "fileContents": true,
            "secrets": true,
            "env": true,
            "authorityGrantIds": true,
            "unsafePaths": true,
            "activationExecution": true
        }
    })
}

fn resource_version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}

async fn inspect_procedural_prerequisite(
    host: &EngineHostHandle,
    invocation: &Invocation,
    resource_id: &str,
    procedural_kind: &str,
    operation: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    let inspection = host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| {
            invalid(format!(
                "{operation} missing procedural record {resource_id}"
            ))
        })?;
    ensure_procedural_record(&inspection, operation)?;
    ensure_readable_scope(&inspection, invocation, operation)?;
    let (_version, payload) = current_payload(&inspection, operation)?;
    validate_record_payload(payload, procedural_kind, operation)?;
    Ok(inspection)
}

async fn inspect_activation_request_prerequisite(
    host: &EngineHostHandle,
    invocation: &Invocation,
    resource_id: &str,
    operation: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    let inspection = host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| {
            invalid(format!(
                "{operation} missing activation request {resource_id}"
            ))
        })?;
    ensure_activation_request(&inspection, operation)?;
    ensure_readable_scope(&inspection, invocation, operation)?;
    Ok(inspection)
}

fn ensure_kind_schema(
    inspection: &EngineResourceInspection,
    kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let expected_schema = match kind {
        PROCEDURAL_ACTIVATION_REQUEST_KIND => PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID,
        PROCEDURAL_ACTIVATION_DECISION_KIND => PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID,
        PROCEDURAL_RECORD_KIND => PROCEDURAL_RECORD_SCHEMA_ID,
        _ => {
            return Err(invalid(format!(
                "{operation} unsupported procedural kind {kind}"
            )));
        }
    };
    if inspection.resource.kind != kind || inspection.resource.schema_id != expected_schema {
        return Err(invalid(format!(
            "{operation} expected {kind} with schema {expected_schema}"
        )));
    }
    Ok(())
}

fn ensure_activation_request(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(inspection, PROCEDURAL_ACTIVATION_REQUEST_KIND, operation)
}

fn ensure_activation_decision(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(inspection, PROCEDURAL_ACTIVATION_DECISION_KIND, operation)
}

fn ensure_scope_matches(
    inspection: &EngineResourceInspection,
    scope: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope == scope {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} cannot use procedural resources outside the selected scope"
        )))
    }
}

fn procedural_ref(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let (version, payload) = current_payload(inspection, operation)?;
    Ok(json!({
        "resourceId": inspection.resource.resource_id,
        "versionId": version.version_id,
        "proceduralKind": payload.get("proceduralKind").cloned().unwrap_or(Value::Null),
        "status": payload.get("status").cloned().unwrap_or(Value::Null)
    }))
}

fn generic_ref(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let (version, payload) = current_payload(inspection, operation)?;
    Ok(json!({
        "resourceId": inspection.resource.resource_id,
        "versionId": version.version_id,
        "kind": inspection.resource.kind,
        "state": payload.get("state").cloned().unwrap_or(Value::Null)
    }))
}

fn record_scope(
    invocation: &Invocation,
    payload: &Value,
) -> Result<EngineResourceScope, CapabilityError> {
    match optional_string(payload, "scope")?.as_deref() {
        Some("workspace") => invocation
            .causal_context
            .workspace_id
            .clone()
            .map(EngineResourceScope::Workspace)
            .ok_or_else(|| invalid("workspace scope requires trusted current workspace context")),
        Some("session") | None => invocation
            .causal_context
            .session_id
            .clone()
            .map(EngineResourceScope::Session)
            .ok_or_else(|| invalid("session scope requires trusted current session context")),
        Some(other) => Err(invalid(format!("unsupported procedural scope {other}"))),
    }
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({
        "kind": scope.kind(),
        "value": scope.value()
    })
}

fn worker_id() -> Result<crate::engine::WorkerId, CapabilityError> {
    crate::engine::WorkerId::new(WORKER).map_err(|error| invalid(error.to_string()))
}

fn resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "metadataOnly": true,
        "networkPolicy": "none",
        "activationExecution": false,
        "repoManagedSkillsTouched": false
    })
}

fn procedural_record_resource_id(
    scope: &EngineResourceScope,
    procedural_kind: &str,
    definition_id: &str,
    idempotency_key: &str,
) -> String {
    format!(
        "procedural_record:{}:{}",
        procedural_kind,
        sha256_hex(
            format!(
                "{}:{}:{definition_id}:{idempotency_key}",
                scope.kind(),
                scope.value()
            )
            .as_bytes()
        )
    )
}

fn activation_request_resource_id(
    scope: &EngineResourceScope,
    request_id: &str,
    idempotency_key: &str,
) -> String {
    format!(
        "procedural_activation_request:{}",
        sha256_hex(
            format!(
                "{}:{}:{request_id}:{idempotency_key}",
                scope.kind(),
                scope.value()
            )
            .as_bytes()
        )
    )
}

fn activation_decision_resource_id(
    scope: &EngineResourceScope,
    decision_id: &str,
    idempotency_key: &str,
) -> String {
    format!(
        "procedural_activation_decision:{}",
        sha256_hex(
            format!(
                "{}:{}:{decision_id}:{idempotency_key}",
                scope.kind(),
                scope.value()
            )
            .as_bytes()
        )
    )
}

fn idempotency_key(invocation: &Invocation, payload: &Value) -> Result<String, CapabilityError> {
    bounded_token(
        "idempotencyKey",
        &optional_string(payload, "idempotencyKey")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
    )
}

fn idempotency_fingerprint(scope: &EngineResourceScope, operation: &str, key: &str) -> String {
    format!(
        "sha256:{}",
        sha256_hex(format!("{}:{}:{operation}:{key}", scope.kind(), scope.value()).as_bytes())
    )
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn bounded_token(label: &str, value: &str) -> Result<String, CapabilityError> {
    if value.len() <= MAX_INPUT_STRING_BYTES
        && !value.trim().is_empty()
        && is_safe_projection_scalar(value)
    {
        Ok(value.to_owned())
    } else {
        Err(invalid(format!(
            "{label} must be a bounded provider-safe token"
        )))
    }
}

fn optional_bounded_token(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    optional_string(payload, field)?
        .map(|value| bounded_token(field, &value))
        .transpose()
}

fn bounded_text(label: &str, value: &str, max_bytes: usize) -> Result<String, CapabilityError> {
    if value.trim().is_empty() || value.len() > max_bytes || provider_unsafe_text(value) {
        return Err(invalid(format!(
            "{label} must be bounded provider-safe text"
        )));
    }
    Ok(value.to_owned())
}

fn optional_bounded_text(
    payload: &Value,
    field: &str,
    max_bytes: usize,
) -> Result<Option<String>, CapabilityError> {
    optional_string(payload, field)?
        .map(|value| bounded_text(field, &value, max_bytes))
        .transpose()
}

fn provider_unsafe_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || lower.contains("grant-")
        || lower.contains("grant_")
        || lower.contains("authoritygrant")
        || lower.contains("/users/")
        || lower.contains("/private/")
        || lower.starts_with('/')
        || lower.contains("~/")
        || lower.contains("~/.")
        || lower.contains(":\\")
}

fn safe_ref_array(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(json!([])),
        Some(Value::Array(items)) if items.len() <= MAX_REFS => {
            for item in items {
                validate_safe_input_value(item, field, 0)?;
            }
            Ok(Value::Array(items.clone()))
        }
        Some(Value::Array(_)) => Err(invalid(format!("{field} exceeds {MAX_REFS} items"))),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

fn safe_input_object(value: Option<&Value>) -> Result<Value, CapabilityError> {
    match value {
        None | Some(Value::Null) => Ok(json!({})),
        Some(Value::Object(_)) => {
            let value = value.expect("checked some");
            validate_safe_input_value(value, "metadata", 0)?;
            Ok(value.clone())
        }
        Some(_) => Err(invalid("metadata fields must be objects")),
    }
}

fn validate_safe_input_value(
    value: &Value,
    label: &str,
    depth: usize,
) -> Result<(), CapabilityError> {
    if depth > 5 {
        return Err(invalid(format!("{label} exceeds max nesting depth")));
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => Ok(()),
        Value::String(text) => bounded_text(label, text, MAX_INPUT_STRING_BYTES).map(|_| ()),
        Value::Array(items) => {
            if items.len() > MAX_REFS {
                return Err(invalid(format!("{label} exceeds {MAX_REFS} items")));
            }
            for item in items {
                validate_safe_input_value(item, label, depth + 1)?;
            }
            Ok(())
        }
        Value::Object(object) => {
            if object.len() > 32 {
                return Err(invalid(format!("{label} has too many fields")));
            }
            for (key, value) in object {
                if provider_unsafe_text(key) {
                    return Err(invalid(format!("{label} contains unsafe key")));
                }
                validate_safe_input_value(value, label, depth + 1)?;
            }
            Ok(())
        }
    }
}

fn scoped_authority_proof(payload: &Value) -> Result<Value, CapabilityError> {
    let proof = safe_input_object(payload.get("scopedAuthorityProof"))?;
    Ok(json!({
        "provided": proof.as_object().is_some_and(|object| !object.is_empty()),
        "proof": proof,
        "grantIdentifiersStored": false,
        "authorityIdentifiersStored": false,
        "wildcardSelectorsAllowed": false,
        "networkPolicy": "none"
    }))
}

fn provider_projection_proof() -> Value {
    json!({
        "metadataOnly": true,
        "rawBodyVisible": false,
        "commandsVisible": false,
        "fileContentsVisible": false,
        "pathsVisible": false,
        "secretsVisible": false,
        "grantIdsVisible": false,
        "authorityIdsVisible": false
    })
}

fn activation_safety_proof() -> Value {
    json!({
        "metadataOnly": true,
        "activationPerformed": false,
        "deactivationPerformed": false,
        "rollbackPerformed": false,
        "triggerRegistered": false,
        "hookFired": false,
        "promptInjected": false,
        "procedureExecuted": false,
        "generatedCodeExecuted": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false
    })
}

fn optional_content_hash(payload: &Value) -> Result<Value, CapabilityError> {
    match payload.get("contentHash") {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(Value::String(text)) if is_safe_content_hash(text) => Ok(Value::String(text.clone())),
        Some(Value::String(_)) => Err(invalid("contentHash must be a sha256 content hash")),
        Some(_) => Err(invalid("contentHash must be a string")),
    }
}

fn activation_request_action(payload: &Value) -> Result<String, CapabilityError> {
    let action =
        optional_string(payload, "requestedAction")?.unwrap_or_else(|| "activate".to_owned());
    match action.as_str() {
        "activate" | "deactivate" | "rollback" => Ok(action),
        _ => Err(invalid(
            "requestedAction must be activate, deactivate, or rollback",
        )),
    }
}

fn activation_decision(payload: &Value) -> Result<String, CapabilityError> {
    let decision = required_string(payload, "decision")?;
    match decision.as_str() {
        "approve_activation" | "deny_activation" | "approve_deactivation" | "approve_rollback" => {
            Ok(decision)
        }
        _ => Err(invalid(
            "decision must be approve_activation, deny_activation, approve_deactivation, or approve_rollback",
        )),
    }
}

fn activation_decision_state(decision: &str) -> &'static str {
    match decision {
        "approve_activation" => "approved",
        "deny_activation" => "denied",
        "approve_deactivation" => "deactivated",
        "approve_rollback" => "rollback_required",
        _ => "denied",
    }
}

fn required_procedural_kind(payload: &Value) -> Result<String, CapabilityError> {
    let kind = required_string(payload, "proceduralKind")?;
    if SUPPORTED_PROCEDURAL_KINDS
        .iter()
        .any(|supported| supported == &kind)
    {
        Ok(kind)
    } else {
        Err(invalid(
            "proceduralKind must be skill, rule, hook, or procedure",
        ))
    }
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?
        .ok_or_else(|| invalid(format!("missing required field {field}")))
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a non-negative integer"))),
        Some(_) => Err(invalid(format!("{field} must be a non-negative integer"))),
    }
}

fn validate_token(value: &str, label: &str) -> Result<(), CapabilityError> {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        Ok(())
    } else {
        Err(invalid(format!("{label} is malformed")))
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "PROCEDURAL_INSPECTION_ENGINE_ERROR".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use serde_json::{Value, json};

    pub(crate) fn procedural_payload(procedural_kind: &str, summary: &str, status: &str) -> Value {
        json!({
            "schemaVersion": super::SCHEMA_VERSION,
            "proceduralKind": procedural_kind,
            "identity": {
                "id": format!("{procedural_kind}.demo"),
                "name": format!("Demo {procedural_kind}"),
                "version": "1.0.0",
                "namespace": "procedural.demo"
            },
            "summary": summary,
            "status": status,
            "provenance": {
                "source": "test",
                "authorityGrantId": "grant-procedural-secret-123",
                "sourcePath": "/Users/example/private/procedure.md",
                "nested": {
                    "credential": "secret-token",
                    "grant_id": "grant-procedural-nested-123",
                    "note": "reviewed"
                }
            },
            "eval": {
                "status": "passed",
                "profile": "schema-only",
                "lastRunAt": "2026-06-25T00:00:00Z",
                "failure": {"message": "failed with grant-procedural-failure at /private/path"}
            },
            "activation": {
                "available": false,
                "reason": "inspection_only"
            },
            "sourceRefs": [{"resourceId": "evidence:one", "path": "/private/path"}],
            "traceRefs": [{"traceId": "trace-procedural", "grantId": "grant-procedural-trace"}],
            "replayRefs": [{"replayId": "replay-procedural", "authority_grant_id": "grant-procedural-replay"}],
            "validationEvidence": {
                "status": "passed",
                "evidenceRefs": [{"resourceId": "validation:one"}]
            },
            "review": {
                "state": "pending_review",
                "required": true,
                "reviewRefs": [{"resourceId": "review:one"}]
            },
            "triggerDeclarations": [{"kind": "manual", "summary": "manual review only"}],
            "conflictMetadata": {"strategy": "deny_on_conflict"},
            "orderingMetadata": {"priority": "normal"},
            "scopedAuthorityProof": {
                "networkPolicy": "none",
                "wildcardSelectorsAllowed": false
            },
            "boundedRefs": [{"resourceId": "bounded:one"}],
            "idempotency": {
                "algorithm": "sha256:tron.procedural.idempotency.v1",
                "fingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            },
            "providerProjection": {
                "metadataOnly": true,
                "rawBodyVisible": false,
                "grantIdsVisible": false
            },
            "revision": 1,
            "body": "raw secret procedure body",
            "manifest": {"raw": "raw manifest"},
            "implementation": {"command": "run dangerous thing"},
            "contentRef": {"uri": "/private/procedural/body.md"},
            "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        })
    }
}
