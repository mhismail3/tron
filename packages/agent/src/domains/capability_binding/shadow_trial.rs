use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

use crate::domains::capability::OperationBindingMetadata;
use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceInspection,
    EngineResourceLocation, EngineResourceScope, EngineResourceVersion, Invocation,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_shadow_trial_write_authority, inspect_shadow_trial_read_grant,
    require_exact_resource_selector,
};
use super::contract::{
    CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION, CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION,
    READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::payload_safety::reject_unsafe_payload;
use super::records::{
    idempotency_evidence, resource_policy, resource_ref, scope_ref, side_effect_proof,
    stable_resource_id, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_scope, inspect_resource_required,
    publish_lifecycle_event, worker_id,
};
use super::validation::{
    DECISION_ID_MAX_BYTES, IDEMPOTENCY_KEY_MAX_BYTES, MAX_REFS, REQUEST_ID_MAX_BYTES,
    SUMMARY_MAX_BYTES, TITLE_MAX_BYTES, TOKEN_MAX_BYTES, bounded_provider_visible_token,
    bounded_text, idempotency_key, invalid, optional_array, optional_string, required_ref,
    required_string, resource_scope, stale_version_guard, target_operation_binding_metadata,
    validate_ref_array,
};
use super::{
    CAPABILITY_SHADOW_TRIAL_DECISION_KIND, CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND, CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_REQUEST_KIND, CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_RUN_KIND, CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
};

const TARGET_OPERATION: &str = "git_status";
const TRIAL_ID_MAX_BYTES: usize = REQUEST_ID_MAX_BYTES;
const RUN_ID_MAX_BYTES: usize = DECISION_ID_MAX_BYTES;
const EVIDENCE_ID_MAX_BYTES: usize = DECISION_ID_MAX_BYTES;
const REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_shadow_trial_request.idempotency.v1";
const DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_shadow_trial_decision.idempotency.v1";
const RUN_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_shadow_trial_run.idempotency.v1";
const EVIDENCE_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_shadow_trial_evidence.idempotency.v1";
const REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_shadow_trial_request.idempotency.v1\0";
const DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_shadow_trial_decision.idempotency.v1\0";
const RUN_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_shadow_trial_run.idempotency.v1\0";
const EVIDENCE_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_shadow_trial_evidence.idempotency.v1\0";

pub(crate) async fn record_capability_shadow_trial_request_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_shadow_trial_write_authority(host, invocation, "capability_shadow_trial_request_record")
        .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let trial_request_id_input = optional_string(payload, "capabilityShadowTrialRequestId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let trial_request_id = bounded_provider_visible_token(
        "capabilityShadowTrialRequestId",
        &trial_request_id_input,
        TRIAL_ID_MAX_BYTES,
    )?;
    let state = shadow_request_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let target_metadata = shadow_target_metadata(payload)?;
    let candidate = candidate_adapter(payload)?;
    let rationale = bounded_text(
        "rationale",
        &required_string(payload, "rationale")?,
        SUMMARY_MAX_BYTES,
    )?;
    let requirements = shadow_requirements(payload)?;
    let audit_refs = validate_ref_array(
        "auditRefs",
        &optional_array(payload, "auditRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let now = operation_at.to_rfc3339();
    let resource_id = shadow_trial_request_resource_id(&scope, &trial_request_id, &idempotency_key);

    if let Some(existing) = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_shadow_trial_request(&existing, "capability_shadow_trial_request_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_shadow_trial_request_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_shadow_trial_request_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION,
            "operation": "capability_shadow_trial_request_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityShadowTrialRequestResourceId": resource_id,
            "capabilityShadowTrialRequestVersionId": version.version_id,
            "shadowTrialRequest": shadow_trial_request_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_shadow_trial_request")]
        }));
    }

    let record = json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION,
        "state": state,
        "trialRequestId": trial_request_id,
        "scope": scope_ref(&scope),
        "title": title,
        "operation": shadow_operation_record(&target_metadata),
        "candidate": candidate,
        "requirements": requirements,
        "trialDecision": {
            "status": "pending_review",
            "decisionRequired": true,
            "runAllowed": false,
            "routingEnabled": false,
            "metadataOnly": true
        },
        "rationale": rationale,
        "auditRefs": audit_refs,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "authority": shadow_authority_record(),
        "idempotency": idempotency_evidence(
            &idempotency_key,
            REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: CAPABILITY_SHADOW_TRIAL_REQUEST_KIND.to_owned(),
            schema_id: Some(CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(CAPABILITY_SHADOW_TRIAL_REQUEST_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "capability_shadow_trial_request".to_owned(),
                uri: format!("capability-shadow-trial-request:{trial_request_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability shadow trial request resource was created without a current version")
    })?;
    publish_lifecycle_event(
        host,
        invocation,
        "capability_shadow_trial.request_recorded",
        &resource,
        json!({
            "shadowTrialRequestState": state,
            "targetOperation": target_metadata.operation,
            "candidateAdapterId": resource_candidate_id(&candidate),
            "metadataOnly": true,
            "runAllowed": false,
            "runtimeRoutingChanged": false,
            "dispatchTableMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION,
        "operation": "capability_shadow_trial_request_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityShadowTrialRequestResourceId": resource.resource_id,
        "capabilityShadowTrialRequestVersionId": version_id,
        "shadowTrialRequest": shadow_trial_request_summary_for_resource(host, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_shadow_trial_request")]
    }))
}

pub(crate) async fn record_capability_shadow_trial_decision_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_shadow_trial_write_authority(
        host,
        invocation,
        "capability_shadow_trial_decision_record",
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let trial_decision_id_input = optional_string(payload, "capabilityShadowTrialDecisionId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let trial_decision_id = bounded_provider_visible_token(
        "capabilityShadowTrialDecisionId",
        &trial_decision_id_input,
        TRIAL_ID_MAX_BYTES,
    )?;
    let request_resource_id = required_string(payload, "capabilityShadowTrialRequestResourceId")?;
    validate_shadow_trial_request_resource_id(&request_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &request_resource_id,
        "capability_shadow_trial_decision_record",
    )?;
    let request_inspection = inspect_resource_required(
        host,
        &request_resource_id,
        "capability shadow trial request",
    )
    .await?;
    ensure_shadow_trial_request(
        &request_inspection,
        "capability_shadow_trial_decision_record",
    )?;
    ensure_scope(
        &request_inspection,
        &scope,
        "capability_shadow_trial_decision_record",
    )?;
    let (request_version, request_payload) = current_payload(
        &request_inspection,
        "capability_shadow_trial_decision_record",
    )?;
    let expected_version =
        required_string(payload, "expectedCapabilityShadowTrialRequestVersionId")?;
    if expected_version != request_version.version_id {
        return Err(invalid(format!(
            "stale capability shadow trial request version {expected_version}"
        )));
    }
    let (state, decision_result) = shadow_decision_state(payload)?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let decision_evidence = validate_ref_array(
        "decisionEvidence",
        &optional_array(payload, "decisionEvidence")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let denial_evidence = validate_ref_array(
        "denialEvidence",
        &optional_array(payload, "denialEvidence")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if state == "rejected" && denial_evidence.is_empty() {
        return Err(invalid(
            "capability shadow trial rejected decisions require denialEvidence",
        ));
    }
    let now = operation_at.to_rfc3339();
    let resource_id =
        shadow_trial_decision_resource_id(&scope, &trial_decision_id, &idempotency_key);

    if let Some(existing) = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_shadow_trial_decision(&existing, "capability_shadow_trial_decision_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_shadow_trial_decision_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_shadow_trial_decision_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION,
            "operation": "capability_shadow_trial_decision_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityShadowTrialDecisionResourceId": resource_id,
            "capabilityShadowTrialDecisionVersionId": version.version_id,
            "shadowTrialDecision": shadow_trial_decision_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_shadow_trial_decision")]
        }));
    }

    let run_allowed = state == "approved_trial";
    let record = json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION,
        "state": state,
        "trialDecisionId": trial_decision_id,
        "scope": request_payload["scope"],
        "request": version_ref(&request_inspection.resource, request_version, "shadow_trial_request"),
        "operation": request_payload["operation"],
        "candidate": request_payload["candidate"],
        "requirements": request_payload["requirements"],
        "decision": {
            "state": state,
            "result": decision_result,
            "reason": reason,
            "decisionEvidence": decision_evidence,
            "denialEvidence": denial_evidence,
            "metadataOnly": true,
            "runtimeRoutingChanged": false,
            "dispatchTableMutated": false,
            "hotSwapPerformed": false,
            "moduleExecuted": false
        },
        "runGate": {
            "runAllowed": run_allowed,
            "requiresMetadataOnlyCandidate": true,
            "requiresProviderSafeProjections": true,
            "targetOperation": TARGET_OPERATION,
            "networkPolicy": "none",
            "routingEnabled": false
        },
        "auditRefs": request_payload["auditRefs"],
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "authority": shadow_authority_record(),
        "idempotency": idempotency_evidence(
            &idempotency_key,
            DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: CAPABILITY_SHADOW_TRIAL_DECISION_KIND.to_owned(),
            schema_id: Some(CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(CAPABILITY_SHADOW_TRIAL_DECISION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "capability_shadow_trial_decision".to_owned(),
                uri: format!("capability-shadow-trial-decision:{trial_decision_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability shadow trial decision resource was created without a current version")
    })?;
    publish_lifecycle_event(
        host,
        invocation,
        if run_allowed {
            "capability_shadow_trial.approved"
        } else {
            "capability_shadow_trial.rejected_or_disabled"
        },
        &resource,
        json!({
            "shadowTrialDecisionState": state,
            "runAllowed": run_allowed,
            "metadataOnly": true,
            "runtimeRoutingChanged": false,
            "dispatchTableMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION,
        "operation": "capability_shadow_trial_decision_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityShadowTrialDecisionResourceId": resource.resource_id,
        "capabilityShadowTrialDecisionVersionId": version_id,
        "shadowTrialDecision": shadow_trial_decision_summary_for_resource(host, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_shadow_trial_decision")]
    }))
}

pub(crate) async fn record_capability_shadow_trial_run_value_at(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_shadow_trial_write_authority(host, invocation, "capability_shadow_trial_run_record")
            .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let trial_run_id_input = optional_string(payload, "capabilityShadowTrialRunId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let trial_run_id = bounded_provider_visible_token(
        "capabilityShadowTrialRunId",
        &trial_run_id_input,
        RUN_ID_MAX_BYTES,
    )?;
    let trial_evidence_id_input = optional_string(payload, "capabilityShadowTrialEvidenceId")?
        .unwrap_or_else(|| format!("{trial_run_id}-evidence"));
    let trial_evidence_id = bounded_provider_visible_token(
        "capabilityShadowTrialEvidenceId",
        &trial_evidence_id_input,
        EVIDENCE_ID_MAX_BYTES,
    )?;
    let decision_resource_id = required_string(payload, "capabilityShadowTrialDecisionResourceId")?;
    validate_shadow_trial_decision_resource_id(&decision_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &decision_resource_id,
        "capability_shadow_trial_run_record",
    )?;
    let decision_inspection = inspect_resource_required(
        host,
        &decision_resource_id,
        "capability shadow trial decision",
    )
    .await?;
    ensure_shadow_trial_decision(&decision_inspection, "capability_shadow_trial_run_record")?;
    ensure_scope(
        &decision_inspection,
        &scope,
        "capability_shadow_trial_run_record",
    )?;
    if decision_inspection.resource.lifecycle != "approved_trial" {
        return Err(invalid(
            "capability shadow trial run requires an approved_trial decision",
        ));
    }
    let (decision_version, decision_payload) =
        current_payload(&decision_inspection, "capability_shadow_trial_run_record")?;
    let expected_version =
        required_string(payload, "expectedCapabilityShadowTrialDecisionVersionId")?;
    if expected_version != decision_version.version_id {
        return Err(invalid(format!(
            "stale capability shadow trial decision version {expected_version}"
        )));
    }
    let run_outcome = shadow_run_outcome(payload)?;
    let (run_state, evidence_state, built_in_projection, candidate_projection, comparison) =
        if run_outcome == "completed" {
            let built_in = status_projection(payload, "builtInProjection")?;
            let candidate = status_projection(payload, "candidateProjection")?;
            let comparison = compare_status_projections(&built_in, &candidate);
            let state = if comparison["result"] == json!("equivalent") {
                "passed"
            } else {
                "failed"
            };
            let evidence_state = if state == "passed" {
                "accepted"
            } else {
                "rejected"
            };
            (
                state.to_owned(),
                evidence_state.to_owned(),
                built_in,
                candidate,
                comparison,
            )
        } else {
            let projection = not_evaluated_projection();
            let comparison = json!({
                "result": run_outcome,
                "comparedFields": [],
                "differences": [],
                "metadataOnly": true,
                "candidateExecuted": false,
                "runtimeRoutingChanged": false,
                "dispatchTableMutated": false
            });
            (
                run_outcome.clone(),
                run_outcome.clone(),
                projection.clone(),
                projection,
                comparison,
            )
        };
    let result_controls = result_controls(decision_payload)?;
    let audit_refs = validate_ref_array(
        "auditRefs",
        &optional_array(payload, "auditRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let now = operation_at.to_rfc3339();
    let run_resource_id = shadow_trial_run_resource_id(&scope, &trial_run_id, &idempotency_key);
    let evidence_resource_id =
        shadow_trial_evidence_resource_id(&scope, &trial_evidence_id, &run_resource_id);

    if let Some(existing) = host
        .inspect_resource(&run_resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_shadow_trial_run(&existing, "capability_shadow_trial_run_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_shadow_trial_run_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_shadow_trial_run_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION,
            "operation": "capability_shadow_trial_run_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityShadowTrialRunResourceId": run_resource_id,
            "capabilityShadowTrialRunVersionId": version.version_id,
            "capabilityShadowTrialEvidenceResourceId": payload["evidence"]["resourceId"],
            "shadowTrialRun": shadow_trial_run_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_shadow_trial_run")]
        }));
    }

    let evidence_record = json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_VERSION,
        "state": evidence_state,
        "trialEvidenceId": trial_evidence_id,
        "scope": decision_payload["scope"],
        "run": {
            "kind": CAPABILITY_SHADOW_TRIAL_RUN_KIND,
            "resourceId": run_resource_id,
            "role": "shadow_trial_run",
            "schemaId": CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
            "lifecycle": run_state
        },
        "decision": version_ref(&decision_inspection.resource, decision_version, "shadow_trial_decision"),
        "request": decision_payload["request"],
        "operation": decision_payload["operation"],
        "candidate": decision_payload["candidate"],
        "builtInProjection": built_in_projection,
        "candidateProjection": candidate_projection,
        "comparison": comparison,
        "resultControls": result_controls,
        "auditRefs": audit_refs,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "authority": shadow_authority_record(),
        "idempotency": idempotency_evidence(
            &idempotency_key,
            EVIDENCE_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            EVIDENCE_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let evidence_resource = host
        .create_resource(CreateResource {
            resource_id: Some(evidence_resource_id.clone()),
            kind: CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND.to_owned(),
            schema_id: Some(CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(evidence_state.clone()),
            policy: resource_policy(CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND),
            initial_payload: Some(evidence_record),
            locations: vec![EngineResourceLocation {
                kind: "capability_shadow_trial_evidence".to_owned(),
                uri: format!("capability-shadow-trial-evidence:{trial_evidence_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let evidence_version_id = evidence_resource
        .current_version_id
        .clone()
        .ok_or_else(|| {
            invalid(
                "capability shadow trial evidence resource was created without a current version",
            )
        })?;
    let run_record = json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION,
        "state": run_state,
        "trialRunId": trial_run_id,
        "scope": decision_payload["scope"],
        "decision": version_ref(&decision_inspection.resource, decision_version, "shadow_trial_decision"),
        "request": decision_payload["request"],
        "operation": decision_payload["operation"],
        "candidate": decision_payload["candidate"],
        "run": {
            "outcome": run_outcome,
            "targetOperation": TARGET_OPERATION,
            "metadataOnly": true,
            "candidateExecuted": false,
            "builtInReExecuted": false,
            "moduleActivated": false,
            "networkPolicy": "none",
            "routingEnabled": false
        },
        "evidence": resource_ref(&evidence_resource, "shadow_trial_evidence"),
        "resultControls": result_controls,
        "auditRefs": audit_refs,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "authority": shadow_authority_record(),
        "idempotency": idempotency_evidence(
            &idempotency_key,
            RUN_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            RUN_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let run_resource = host
        .create_resource(CreateResource {
            resource_id: Some(run_resource_id.clone()),
            kind: CAPABILITY_SHADOW_TRIAL_RUN_KIND.to_owned(),
            schema_id: Some(CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(run_state.clone()),
            policy: resource_policy(CAPABILITY_SHADOW_TRIAL_RUN_KIND),
            initial_payload: Some(run_record),
            locations: vec![EngineResourceLocation {
                kind: "capability_shadow_trial_run".to_owned(),
                uri: format!("capability-shadow-trial-run:{trial_run_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let run_version_id = run_resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability shadow trial run resource was created without a current version")
    })?;
    publish_lifecycle_event(
        host,
        invocation,
        "capability_shadow_trial.run_recorded",
        &run_resource,
        json!({
            "shadowTrialRunState": run_state,
            "shadowTrialEvidenceState": evidence_state,
            "evidenceResourceId": evidence_resource.resource_id,
            "evidenceVersionId": evidence_version_id,
            "metadataOnly": true,
            "candidateExecuted": false,
            "runtimeRoutingChanged": false,
            "dispatchTableMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION,
        "operation": "capability_shadow_trial_run_record",
        "status": run_resource.lifecycle,
        "idempotentReplay": false,
        "capabilityShadowTrialRunResourceId": run_resource.resource_id,
        "capabilityShadowTrialRunVersionId": run_version_id,
        "capabilityShadowTrialEvidenceResourceId": evidence_resource.resource_id,
        "capabilityShadowTrialEvidenceVersionId": evidence_version_id,
        "shadowTrialRun": shadow_trial_run_summary_for_resource(host, &run_resource).await?,
        "shadowTrialEvidence": shadow_trial_evidence_summary_for_resource(host, &evidence_resource).await?,
        "resourceRefs": [
            resource_ref(&run_resource, "capability_shadow_trial_run"),
            resource_ref(&evidence_resource, "capability_shadow_trial_evidence")
        ]
    }))
}

pub(crate) async fn inspect_capability_shadow_trial_evidence_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_shadow_trial_read_grant(
        host,
        invocation,
        "capability_shadow_trial_evidence_inspect",
    )
    .await?;
    let resource_id = required_string(payload, "capabilityShadowTrialEvidenceResourceId")?;
    validate_shadow_trial_evidence_resource_id(&resource_id)?;
    require_exact_resource_selector(
        &grant,
        &resource_id,
        "capability_shadow_trial_evidence_inspect",
    )?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(host, &resource_id, "capability shadow trial evidence").await?;
    ensure_shadow_trial_evidence(&inspection, "capability_shadow_trial_evidence_inspect")?;
    ensure_scope(
        &inspection,
        &scope,
        "capability_shadow_trial_evidence_inspect",
    )?;
    let (version, stored_payload) =
        current_payload(&inspection, "capability_shadow_trial_evidence_inspect")?;
    if let Some(expected_version) =
        optional_string(payload, "expectedCapabilityShadowTrialEvidenceVersionId")?
        && expected_version != version.version_id
    {
        return Err(invalid(format!(
            "stale capability shadow trial evidence version {expected_version}"
        )));
    }
    Ok(json!({
        "schemaVersion": CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_VERSION,
        "operation": "capability_shadow_trial_evidence_inspect",
        "scope": scope_ref(&scope),
        "shadowTrialEvidence": inspected_shadow_trial_evidence(&inspection.resource, version, stored_payload),
        "sideEffects": side_effect_proof()
    }))
}

fn shadow_request_state(payload: &Value) -> Result<String, CapabilityError> {
    let state =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(state.as_str(), "pending_review" | "disabled" | "aborted") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported capability shadow trial request lifecycle {state}"
        )))
    }
}

fn shadow_target_metadata(payload: &Value) -> Result<OperationBindingMetadata, CapabilityError> {
    if let Some(mode) = optional_string(payload, "bindingMode")?
        && mode != "shadow"
    {
        return Err(invalid(
            "capability shadow trials require bindingMode shadow when supplied",
        ));
    }
    let metadata = target_operation_binding_metadata(payload)?;
    if metadata.operation != TARGET_OPERATION {
        return Err(invalid(format!(
            "capability shadow trial target must be exactly {TARGET_OPERATION}"
        )));
    }
    if metadata.ownership_class != "adapter_replaceable" {
        return Err(invalid(
            "capability shadow trial target must be adapter_replaceable",
        ));
    }
    Ok(metadata)
}

fn candidate_adapter(payload: &Value) -> Result<Value, CapabilityError> {
    let map = required_object(payload, "candidateAdapter")?;
    let adapter_id = required_object_string(map, "candidateAdapter", "adapterId")?;
    let adapter_version = required_object_string(map, "candidateAdapter", "adapterVersion")?;
    let adapter_kind = map
        .get("adapterKind")
        .and_then(Value::as_str)
        .unwrap_or("deterministic_projection");
    let execution_mode = required_object_string(map, "candidateAdapter", "executionMode")?;
    if execution_mode != "metadata_only" {
        return Err(invalid(
            "candidateAdapter.executionMode must be metadata_only",
        ));
    }
    let network_policy = required_object_string(map, "candidateAdapter", "networkPolicy")?;
    if network_policy != "none" {
        return Err(invalid("candidateAdapter.networkPolicy must be none"));
    }
    for (field, expected) in [
        ("moduleExecution", false),
        ("packageManagerUsed", false),
        ("runtimeRoutingEnabled", false),
        ("agentStateInherited", false),
    ] {
        let actual = map
            .get(field)
            .and_then(Value::as_bool)
            .ok_or_else(|| invalid(format!("candidateAdapter.{field} is required")))?;
        if actual != expected {
            return Err(invalid(format!(
                "candidateAdapter.{field} must be {expected}"
            )));
        }
    }
    let description = map
        .get("description")
        .and_then(Value::as_str)
        .map(|value| bounded_text("candidateAdapter.description", value, SUMMARY_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "Deterministic metadata-only git_status shadow projection.".to_owned());
    Ok(json!({
        "adapterId": bounded_provider_visible_token(
            "candidateAdapter.adapterId",
            adapter_id,
            TOKEN_MAX_BYTES,
        )?,
        "adapterVersion": bounded_provider_visible_token(
            "candidateAdapter.adapterVersion",
            adapter_version,
            TOKEN_MAX_BYTES,
        )?,
        "adapterKind": bounded_provider_visible_token(
            "candidateAdapter.adapterKind",
            adapter_kind,
            TOKEN_MAX_BYTES,
        )?,
        "description": description,
        "executionMode": "metadata_only",
        "networkPolicy": "none",
        "moduleExecution": false,
        "packageManagerUsed": false,
        "runtimeRoutingEnabled": false,
        "agentStateInherited": false,
        "providerSafeProjectionOnly": true
    }))
}

fn shadow_requirements(payload: &Value) -> Result<Value, CapabilityError> {
    let contract_refs = validate_ref_array(
        "contractEvidenceRefs",
        &optional_array(payload, "contractEvidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if contract_refs.is_empty() {
        return Err(invalid(
            "capability shadow trial requests require contractEvidenceRefs",
        ));
    }
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if evidence_refs.is_empty() {
        return Err(invalid(
            "capability shadow trial requests require evidenceRefs",
        ));
    }
    let rollback_ref = required_ref(payload, "rollbackRef")?;
    let disable_ref = required_ref(payload, "disableRef")?;
    let abort_ref = required_ref(payload, "abortRef")?;
    Ok(json!({
        "contract": {
            "contractEvidenceRefs": contract_refs,
            "evidenceRefs": evidence_refs,
            "providerSafeProjectionRequired": true,
            "runtimeParityRequired": true,
            "contractCompatible": false
        },
        "authority": exact_authority_constraints(payload)?,
        "staleVersionGuard": stale_version_guard(payload)?,
        "rollbackRef": rollback_ref,
        "disableRef": disable_ref,
        "abortRef": abort_ref,
        "networkPolicy": "none",
        "noStateInheritance": true,
        "noRuntimeRouting": true
    }))
}

fn exact_authority_constraints(payload: &Value) -> Result<Value, CapabilityError> {
    let map = required_object(payload, "authorityConstraints")?;
    let network_policy = required_object_string(map, "authorityConstraints", "networkPolicy")?;
    if network_policy != "none" {
        return Err(invalid(
            "capability shadow trial requires authorityConstraints.networkPolicy none",
        ));
    }
    if map
        .get("agentStateInherited")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Err(invalid(
            "capability shadow trial rejects agent_state inheritance",
        ));
    }
    let authority_scopes = exact_string_array(map, "authorityConstraints", "authorityScopes")?;
    let resource_kinds = exact_string_array(map, "authorityConstraints", "resourceKinds")?;
    if resource_kinds
        .iter()
        .any(|value| value.as_str() == Some("agent_state"))
    {
        return Err(invalid(
            "capability shadow trial rejects agent_state resourceKinds",
        ));
    }
    let resource_selectors = exact_string_array(map, "authorityConstraints", "resourceSelectors")?;
    if resource_selectors.is_empty() {
        return Err(invalid(
            "capability shadow trial requires exact resourceSelectors",
        ));
    }
    for selector in &resource_selectors {
        let selector = selector.as_str().expect("selector strings");
        if !selector.starts_with("resource:") || is_broad_selector(selector) {
            return Err(invalid(
                "capability shadow trial requires non-wildcard exact resource selectors",
            ));
        }
    }
    Ok(json!({
        "networkPolicy": "none",
        "authorityScopes": authority_scopes,
        "resourceKinds": resource_kinds,
        "resourceSelectors": resource_selectors,
        "agentStateInherited": false,
        "rawGrantIdsStored": false,
        "wildcardSelectorsAllowed": false,
        "exactSelectorsRequired": true
    }))
}

fn shadow_decision_state(payload: &Value) -> Result<(String, String), CapabilityError> {
    let decision = required_string(payload, "decision")?;
    let state = match decision.as_str() {
        "approved" => "approved_trial",
        "rejected" | "denied" => "rejected",
        "disabled" => "disabled",
        "aborted" => "aborted",
        _ => {
            return Err(invalid(format!(
                "unsupported capability shadow trial decision {decision}"
            )));
        }
    };
    Ok((state.to_owned(), decision))
}

fn shadow_run_outcome(payload: &Value) -> Result<String, CapabilityError> {
    let outcome =
        optional_string(payload, "trialRunOutcome")?.unwrap_or_else(|| "completed".to_owned());
    if matches!(outcome.as_str(), "completed" | "aborted" | "disabled") {
        Ok(outcome)
    } else {
        Err(invalid(format!(
            "unsupported capability shadow trial run outcome {outcome}"
        )))
    }
}

fn status_projection(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    let map = required_object(payload, field)?;
    let operation = required_object_string(map, field, "operation")?;
    if operation != TARGET_OPERATION {
        return Err(invalid(format!(
            "{field}.operation must be {TARGET_OPERATION}"
        )));
    }
    let status = enum_object_string(
        map,
        field,
        "status",
        &["clean", "dirty", "unavailable", "unknown"],
    )?;
    let head_state = enum_object_string(map, field, "headState", &["known", "unknown"])?;
    let index_state = enum_object_string(map, field, "indexState", &["known", "unknown"])?;
    let worktree_state =
        enum_object_string(map, field, "worktreeState", &["clean", "dirty", "unknown"])?;
    let truncation = map
        .get("truncation")
        .and_then(Value::as_str)
        .unwrap_or("none");
    if !matches!(truncation, "none" | "bounded" | "truncated" | "unknown") {
        return Err(invalid(format!("{field}.truncation has unsupported value")));
    }
    let evidence_ref = required_projection_evidence_ref(map, field)?;
    Ok(json!({
        "operation": TARGET_OPERATION,
        "status": status,
        "headState": head_state,
        "indexState": index_state,
        "worktreeState": worktree_state,
        "truncation": bounded_provider_visible_token(
            &format!("{field}.truncation"),
            truncation,
            TOKEN_MAX_BYTES,
        )?,
        "evidenceRef": evidence_ref,
        "providerSafe": true,
        "rawStatusStored": false,
        "rawDiffStored": false,
        "rawPathsStored": false,
        "rawCommandsStored": false
    }))
}

fn required_projection_evidence_ref(
    map: &Map<String, Value>,
    field: &str,
) -> Result<Value, CapabilityError> {
    let Some(value) = map.get("evidenceRef") else {
        return Err(invalid(format!(
            "{field}.evidenceRef is required for completed shadow trial projections"
        )));
    };
    let evidence_ref = required_ref(&json!({"evidenceRef": value}), "evidenceRef")?;
    let resource_id = evidence_ref
        .get("resourceId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if resource_id == "evidence:none" || resource_id.starts_with("evidence:none:") {
        return Err(invalid(format!(
            "{field}.evidenceRef must reference concrete shadow projection evidence"
        )));
    }
    Ok(evidence_ref)
}

fn not_evaluated_projection() -> Value {
    json!({
        "operation": TARGET_OPERATION,
        "status": "not_evaluated",
        "headState": "not_evaluated",
        "indexState": "not_evaluated",
        "worktreeState": "not_evaluated",
        "truncation": "none",
        "providerSafe": true,
        "rawStatusStored": false,
        "rawDiffStored": false,
        "rawPathsStored": false,
        "rawCommandsStored": false
    })
}

fn compare_status_projections(built_in: &Value, candidate: &Value) -> Value {
    let fields = ["status", "headState", "indexState", "worktreeState"];
    let mut differences = Vec::new();
    let mut unknown = false;
    for field in fields {
        let built_in_value = built_in
            .get(field)
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let candidate_value = candidate
            .get(field)
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        if matches!(built_in_value, "unknown" | "unavailable")
            || matches!(candidate_value, "unknown" | "unavailable")
        {
            unknown = true;
        }
        if built_in_value != candidate_value {
            differences.push(json!({
                "field": field,
                "builtIn": built_in_value,
                "candidate": candidate_value
            }));
        }
    }
    let result = if differences.is_empty() && !unknown {
        "equivalent"
    } else if differences.is_empty() {
        "inconclusive"
    } else {
        "diverged"
    };
    json!({
        "result": result,
        "comparedFields": fields,
        "differences": differences,
        "metadataOnly": true,
        "candidateExecuted": false,
        "runtimeRoutingChanged": false,
        "dispatchTableMutated": false
    })
}

fn result_controls(decision_payload: &Value) -> Result<Value, CapabilityError> {
    let requirements = decision_payload
        .get("requirements")
        .ok_or_else(|| invalid("shadow trial decision requirements are missing"))?;
    Ok(json!({
        "rollbackRef": requirements["rollbackRef"],
        "disableRef": requirements["disableRef"],
        "abortRef": requirements["abortRef"],
        "rollbackAvailable": true,
        "disableAvailable": true,
        "abortAvailable": true,
        "routingWasNeverChanged": true,
        "liveReplacementPerformed": false
    }))
}

fn shadow_operation_record(metadata: &OperationBindingMetadata) -> Value {
    json!({
        "name": metadata.operation,
        "family": metadata.family,
        "currentBuiltInOwner": metadata.current_owner,
        "ownershipClass": metadata.ownership_class,
        "requestedReplacementTarget": metadata.replacement_target,
        "currentExecutionOwner": "builtin",
        "dispatchChanged": false,
        "trialTarget": true
    })
}

fn shadow_authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "derivedRuntimeGrantRequired": true,
        "approvalEvidenceIsAuthority": false,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [
            CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
            CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
            CAPABILITY_SHADOW_TRIAL_RUN_KIND,
            CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND
        ],
        "wildcardGrantsAllowed": false,
        "exactSelectorsRequired": true,
        "agentStateInherited": false
    })
}

fn shadow_trial_request_summary_for_resource<'a>(
    host: &'a EngineHostHandle,
    resource: &'a EngineResource,
) -> impl std::future::Future<Output = Result<Value, CapabilityError>> + 'a {
    async move {
        let inspection = inspect_resource_required(
            host,
            &resource.resource_id,
            "capability shadow trial request",
        )
        .await?;
        let (version, payload) = current_payload(
            &inspection,
            "capability_shadow_trial_request_record projection",
        )?;
        Ok(shadow_trial_request_summary(
            &inspection.resource,
            version,
            payload,
        ))
    }
}

fn shadow_trial_decision_summary_for_resource<'a>(
    host: &'a EngineHostHandle,
    resource: &'a EngineResource,
) -> impl std::future::Future<Output = Result<Value, CapabilityError>> + 'a {
    async move {
        let inspection = inspect_resource_required(
            host,
            &resource.resource_id,
            "capability shadow trial decision",
        )
        .await?;
        let (version, payload) = current_payload(
            &inspection,
            "capability_shadow_trial_decision_record projection",
        )?;
        Ok(shadow_trial_decision_summary(
            &inspection.resource,
            version,
            payload,
        ))
    }
}

fn shadow_trial_run_summary_for_resource<'a>(
    host: &'a EngineHostHandle,
    resource: &'a EngineResource,
) -> impl std::future::Future<Output = Result<Value, CapabilityError>> + 'a {
    async move {
        let inspection =
            inspect_resource_required(host, &resource.resource_id, "capability shadow trial run")
                .await?;
        let (version, payload) =
            current_payload(&inspection, "capability_shadow_trial_run_record projection")?;
        Ok(shadow_trial_run_summary(
            &inspection.resource,
            version,
            payload,
        ))
    }
}

fn shadow_trial_evidence_summary_for_resource<'a>(
    host: &'a EngineHostHandle,
    resource: &'a EngineResource,
) -> impl std::future::Future<Output = Result<Value, CapabilityError>> + 'a {
    async move {
        let inspection = inspect_resource_required(
            host,
            &resource.resource_id,
            "capability shadow trial evidence",
        )
        .await?;
        let (version, payload) =
            current_payload(&inspection, "capability_shadow_trial_evidence projection")?;
        Ok(shadow_trial_evidence_summary(
            &inspection.resource,
            version,
            payload,
        ))
    }
}

fn shadow_trial_request_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityShadowTrialRequestResourceId": resource.resource_id,
        "state": resource.lifecycle,
        "trialRequestId": projected_string(payload, "trialRequestId"),
        "operation": payload["operation"],
        "candidate": payload["candidate"],
        "trialDecision": payload["trialDecision"],
        "requirements": projected_requirements(payload.get("requirements")),
        "sideEffectProof": payload["sideEffectProof"],
        "resourceRefs": [version_ref(resource, version, "capability_shadow_trial_request")]
    })
}

fn shadow_trial_decision_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityShadowTrialDecisionResourceId": resource.resource_id,
        "state": resource.lifecycle,
        "trialDecisionId": projected_string(payload, "trialDecisionId"),
        "request": payload["request"],
        "operation": payload["operation"],
        "candidate": payload["candidate"],
        "decision": payload["decision"],
        "runGate": payload["runGate"],
        "sideEffectProof": payload["sideEffectProof"],
        "resourceRefs": [version_ref(resource, version, "capability_shadow_trial_decision")]
    })
}

fn shadow_trial_run_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityShadowTrialRunResourceId": resource.resource_id,
        "state": resource.lifecycle,
        "trialRunId": projected_string(payload, "trialRunId"),
        "decision": payload["decision"],
        "operation": payload["operation"],
        "candidate": payload["candidate"],
        "run": payload["run"],
        "evidence": payload["evidence"],
        "resultControls": payload["resultControls"],
        "sideEffectProof": payload["sideEffectProof"],
        "resourceRefs": [version_ref(resource, version, "capability_shadow_trial_run")]
    })
}

fn shadow_trial_evidence_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityShadowTrialEvidenceResourceId": resource.resource_id,
        "state": resource.lifecycle,
        "trialEvidenceId": projected_string(payload, "trialEvidenceId"),
        "run": payload["run"],
        "operation": payload["operation"],
        "candidate": payload["candidate"],
        "comparison": payload["comparison"],
        "resultControls": payload["resultControls"],
        "sideEffectProof": payload["sideEffectProof"],
        "resourceRefs": [version_ref(resource, version, "capability_shadow_trial_evidence")]
    })
}

fn inspected_shadow_trial_evidence(
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
        "shadowTrialEvidence": {
            "schemaVersion": payload["schemaVersion"],
            "state": payload["state"],
            "trialEvidenceId": payload["trialEvidenceId"],
            "scope": payload["scope"],
            "run": payload["run"],
            "decision": payload["decision"],
            "request": payload["request"],
            "operation": payload["operation"],
            "candidate": payload["candidate"],
            "builtInProjection": payload["builtInProjection"],
            "candidateProjection": payload["candidateProjection"],
            "comparison": payload["comparison"],
            "resultControls": payload["resultControls"],
            "authority": payload["authority"],
            "idempotency": payload["idempotency"],
            "sideEffectProof": payload["sideEffectProof"],
            "createdAt": payload["createdAt"],
            "updatedAt": payload["updatedAt"],
            "revision": payload["revision"]
        },
        "projection": {
            "providerSafe": true,
            "bounded": true,
            "agentStateInherited": false,
            "rawGrantIdsStored": false,
            "rawAuthorityIdsStored": false,
            "rawCommandsStored": false,
            "rawLogsStored": false,
            "rawPathsStored": false,
            "fileContentsStored": false
        },
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_requirements(value: Option<&Value>) -> Value {
    let Some(Value::Object(requirements)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "contract",
        "authority",
        "staleVersionGuard",
        "rollbackRef",
        "disableRef",
        "abortRef",
    ] {
        if let Some(value) = requirements.get(key) {
            projected.insert(key.to_owned(), value.clone());
        }
    }
    Value::Object(projected)
}

fn projected_string(payload: &Value, field: &str) -> Value {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(|value| {
            let clipped = if value.len() > IDEMPOTENCY_KEY_MAX_BYTES {
                &value[..IDEMPOTENCY_KEY_MAX_BYTES]
            } else {
                value
            };
            json!(clipped)
        })
        .unwrap_or(Value::Null)
}

fn ensure_shadow_trial_request(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_shadow_kind_schema(
        inspection,
        operation,
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
        CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID,
    )
}

fn ensure_shadow_trial_decision(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_shadow_kind_schema(
        inspection,
        operation,
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
        CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID,
    )
}

fn ensure_shadow_trial_run(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_shadow_kind_schema(
        inspection,
        operation,
        CAPABILITY_SHADOW_TRIAL_RUN_KIND,
        CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
    )
}

fn ensure_shadow_trial_evidence(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_shadow_kind_schema(
        inspection,
        operation,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID,
    )
}

fn ensure_shadow_kind_schema(
    inspection: &EngineResourceInspection,
    operation: &str,
    kind: &str,
    schema_id: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != kind {
        return Err(invalid(format!("{operation} expected {kind}")));
    }
    if inspection.resource.schema_id != schema_id {
        return Err(invalid(format!("{operation} expected schema {schema_id}")));
    }
    Ok(())
}

fn shadow_trial_request_resource_id(
    scope: &EngineResourceScope,
    trial_request_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
        scope,
        trial_request_id,
        idempotency_key,
    )
}

fn shadow_trial_decision_resource_id(
    scope: &EngineResourceScope,
    trial_decision_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
        scope,
        trial_decision_id,
        idempotency_key,
    )
}

fn shadow_trial_run_resource_id(
    scope: &EngineResourceScope,
    trial_run_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_SHADOW_TRIAL_RUN_KIND,
        scope,
        trial_run_id,
        idempotency_key,
    )
}

fn shadow_trial_evidence_resource_id(
    scope: &EngineResourceScope,
    trial_evidence_id: &str,
    run_resource_id: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
        scope,
        trial_evidence_id,
        run_resource_id,
    )
}

fn validate_shadow_trial_request_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_shadow_trial_request:") {
        return Err(invalid(
            "capabilityShadowTrialRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token(
        "capabilityShadowTrialRequestResourceId",
        value,
        TOKEN_MAX_BYTES,
    )
    .map(|_| ())
}

fn validate_shadow_trial_decision_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_shadow_trial_decision:") {
        return Err(invalid(
            "capabilityShadowTrialDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token(
        "capabilityShadowTrialDecisionResourceId",
        value,
        TOKEN_MAX_BYTES,
    )
    .map(|_| ())
}

fn validate_shadow_trial_evidence_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_shadow_trial_evidence:") {
        return Err(invalid(
            "capabilityShadowTrialEvidenceResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token(
        "capabilityShadowTrialEvidenceResourceId",
        value,
        TOKEN_MAX_BYTES,
    )
    .map(|_| ())
}

fn required_object<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a Map<String, Value>, CapabilityError> {
    payload
        .get(field)
        .and_then(Value::as_object)
        .ok_or_else(|| invalid(format!("{field} must be an object")))
}

fn required_object_string<'a>(
    map: &'a Map<String, Value>,
    label: &str,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    map.get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| invalid(format!("{label}.{field} is required")))
}

fn enum_object_string(
    map: &Map<String, Value>,
    label: &str,
    field: &str,
    values: &[&str],
) -> Result<String, CapabilityError> {
    let value = required_object_string(map, label, field)?;
    if !values.contains(&value) {
        return Err(invalid(format!("{label}.{field} has unsupported value")));
    }
    bounded_provider_visible_token(&format!("{label}.{field}"), value, TOKEN_MAX_BYTES)
}

fn exact_string_array(
    map: &Map<String, Value>,
    label: &str,
    field: &str,
) -> Result<Vec<Value>, CapabilityError> {
    let Some(value) = map.get(field) else {
        return Ok(Vec::new());
    };
    let Value::Array(items) = value else {
        return Err(invalid(format!("{label}.{field} must be an array")));
    };
    if items.len() > MAX_REFS {
        return Err(invalid(format!(
            "{label}.{field} may contain at most {MAX_REFS} items"
        )));
    }
    items
        .iter()
        .map(|item| {
            let text = item
                .as_str()
                .ok_or_else(|| invalid(format!("{label}.{field} entries must be strings")))?;
            bounded_provider_visible_token(&format!("{label}.{field}"), text, TOKEN_MAX_BYTES)
                .map(|value| json!(value))
        })
        .collect()
}

fn is_broad_selector(selector: &str) -> bool {
    let trimmed = selector.trim();
    trimmed == "*"
        || trimmed == "resource:*"
        || trimmed == "kind:*"
        || trimmed == "resource:"
        || trimmed == "kind:"
        || trimmed.ends_with(":*")
}

fn resource_candidate_id(candidate: &Value) -> Value {
    candidate
        .get("adapterId")
        .and_then(Value::as_str)
        .map(|value| json!(value))
        .unwrap_or(Value::Null)
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "resourceId": invocation.causal_context.trace_id.as_str(),
        "role": "capability_shadow_trial_trace",
        "storedRawPayload": false
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "resourceId": invocation.id.as_str(),
        "role": "capability_shadow_trial_replay",
        "idempotent": true,
        "storedRawPayload": false
    })]
}
