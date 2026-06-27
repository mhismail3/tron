use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceLocation, EngineResourceScope, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::approval_gate::check_install_approval;
use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::{
    MODULE_INSTALL_DECISION_SCHEMA_VERSION, MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
};
use super::payload_safety::reject_unsafe_payload;
use super::prerequisite::ensure_validation_report_prerequisite;
use super::projection::{
    inspected_module_install_decision, inspected_module_install_request,
    module_install_decision_summary, module_install_request_summary,
};
use super::records::{
    ModuleInstallDecisionInput, ModuleInstallRequestInput, module_install_decision_record,
    module_install_decision_resource_id, module_install_request_record,
    module_install_request_resource_id, resource_policy, resource_ref, scope_ref,
    side_effect_proof, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_module_install_decision, ensure_module_install_request,
    ensure_scope, inspect_resource_required, module_install_decision_summary_for_resource,
    module_install_request_summary_for_resource, publish_lifecycle_event, worker_id,
};
use super::validation::*;
use super::{
    Deps, MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_DECISION_SCHEMA_ID,
    MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_REQUEST_SCHEMA_ID,
};

pub(crate) async fn record_module_install_request_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "module_install_request_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_id_input = optional_string(payload, "installRequestId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let request_id = bounded_provider_visible_token(
        "installRequestId",
        &request_id_input,
        REQUEST_ID_MAX_BYTES,
    )?;
    let state = request_lifecycle_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let summary = bounded_text(
        "summary",
        &required_string(payload, "summary")?,
        SUMMARY_MAX_BYTES,
    )?;
    let validation_report_resource_id =
        required_string(payload, "moduleValidationReportResourceId")?;
    validate_module_validation_report_resource_id(&validation_report_resource_id)?;
    let validation_report =
        inspect_validation_prerequisite(deps, &validation_report_resource_id, &scope).await?;
    let dependency_policy_refs = validate_ref_array(
        "dependencyPolicyRefs",
        &optional_array(payload, "dependencyPolicyRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let dependency_policy_status = validate_dependency_policy_status(payload)?;
    let rollback_proof_refs = validate_ref_array(
        "rollbackProofRefs",
        &optional_array(payload, "rollbackProofRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let rollback_readiness = validate_rollback_readiness(payload)?;
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let now = operation_at.to_rfc3339();
    let resource_id = module_install_request_resource_id(&scope, &request_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_install_request(&existing, "module_install_request_record replay")?;
        ensure_scope(&existing, &scope, "module_install_request_record replay")?;
        let (version, payload) =
            current_payload(&existing, "module_install_request_record replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
            "operation": "module_install_request_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleInstallRequestResourceId": resource_id,
            "moduleInstallRequestVersionId": version.version_id,
            "installRequest": module_install_request_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_install_request")]
        }));
    }

    let record = module_install_request_record(ModuleInstallRequestInput {
        request_id: &request_id,
        state: &state,
        scope: &scope,
        title: &title,
        summary: &summary,
        validation_report,
        dependency_policy_refs,
        dependency_policy_status,
        rollback_proof_refs,
        rollback_readiness,
        evidence_refs,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MODULE_INSTALL_REQUEST_KIND.to_owned(),
            schema_id: Some(MODULE_INSTALL_REQUEST_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(MODULE_INSTALL_REQUEST_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_install_request".to_owned(),
                uri: format!("module-install-request:{request_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module install request resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_install.request_recorded",
        &resource,
        json!({
            "installRequestState": state,
            "metadataOnly": true,
            "reviewRequired": true,
            "installPerformed": false,
            "executionPerformed": false,
            "dependencyRestorePerformed": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
        "operation": "module_install_request_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleInstallRequestResourceId": resource.resource_id,
        "moduleInstallRequestVersionId": version_id,
        "installRequest": module_install_request_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_install_request")]
    }))
}

pub(crate) async fn list_module_install_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, "module_install_request_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let lifecycle = optional_string(payload, "lifecycle")?
        .map(|value| bounded_token("lifecycle", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MODULE_INSTALL_REQUEST_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some("pending_review".to_owned())
                }
            }),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut requests = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_module_install_request(&inspection, "module_install_request_list")?;
        ensure_scope(&inspection, &scope, "module_install_request_list")?;
        let (version, payload) = current_payload(&inspection, "module_install_request_list")?;
        requests.push(module_install_request_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
        "operation": "module_install_request_list",
        "scope": scope_ref(&scope),
        "installRequests": requests,
        "limits": {
            "requestedLimit": limit,
            "returned": requests.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn inspect_module_install_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_install_request_inspect").await?;
    let resource_id = required_string(payload, "moduleInstallRequestResourceId")?;
    validate_module_install_request_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_install_request_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module install request").await?;
    ensure_module_install_request(&inspection, "module_install_request_inspect")?;
    ensure_scope(&inspection, &scope, "module_install_request_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_install_request_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
        "operation": "module_install_request_inspect",
        "scope": scope_ref(&scope),
        "installRequest": inspected_module_install_request(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn record_module_install_decision_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "module_install_decision_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let decision_id_input = optional_string(payload, "installDecisionId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let decision_id = bounded_provider_visible_token(
        "installDecisionId",
        &decision_id_input,
        DECISION_ID_MAX_BYTES,
    )?;
    let request_resource_id = required_string(payload, "moduleInstallRequestResourceId")?;
    validate_module_install_request_resource_id(&request_resource_id)?;
    let request_inspection =
        inspect_resource_required(deps, &request_resource_id, "module install request").await?;
    ensure_module_install_request(&request_inspection, "module_install_decision_record")?;
    ensure_scope(
        &request_inspection,
        &scope,
        "module_install_decision_record",
    )?;
    let (request_version, request_payload) =
        current_payload(&request_inspection, "module_install_decision_record")?;
    let validation_report_resource_id = request_payload
        .pointer("/validationReport/resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("module install request is missing validation report ref"))?
        .to_owned();
    let validation_report =
        inspect_validation_prerequisite(deps, &validation_report_resource_id, &scope).await?;
    let state = decision_lifecycle_state(payload)?;
    let decision = required_string(payload, "decision")?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let denial_evidence = validate_ref_array(
        "denialEvidence",
        &optional_array(payload, "denialEvidence")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if state == "rejected" && denial_evidence.is_empty() {
        return Err(invalid(
            "module install rejected decisions require denialEvidence",
        ));
    }
    let (approval_request_resource_id, approval_decision_resource_id) =
        validate_approval_refs(payload)?;
    let approval = check_install_approval(
        deps,
        &scope,
        &request_resource_id,
        &validation_report_resource_id,
        &approval_request_resource_id,
        approval_decision_resource_id.as_deref(),
        operation_at,
    )
    .await?;
    let dependency_policy_refs = request_payload
        .pointer("/dependencyPolicy/refs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let dependency_policy_status = request_payload
        .get("dependencyPolicy")
        .cloned()
        .unwrap_or_else(|| json!({"status": "not_required", "metadataOnly": true}));
    let rollback_proof_refs = request_payload
        .pointer("/rollback/proofRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let rollback_readiness = request_payload
        .get("rollback")
        .cloned()
        .unwrap_or_else(|| json!({"status": "not_proven", "metadataOnly": true}));
    let now = operation_at.to_rfc3339();
    let resource_id = module_install_decision_resource_id(&scope, &decision_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_install_decision(&existing, "module_install_decision_record replay")?;
        ensure_scope(&existing, &scope, "module_install_decision_record replay")?;
        let (version, payload) =
            current_payload(&existing, "module_install_decision_record replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_INSTALL_DECISION_SCHEMA_VERSION,
            "operation": "module_install_decision_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleInstallDecisionResourceId": resource_id,
            "moduleInstallDecisionVersionId": version.version_id,
            "installDecision": module_install_decision_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_install_decision")]
        }));
    }

    let record = module_install_decision_record(ModuleInstallDecisionInput {
        decision_id: &decision_id,
        state: &state,
        decision: &decision,
        reason: &reason,
        denial_evidence,
        scope: &scope,
        request_resource: &request_inspection.resource,
        request_version,
        validation_report,
        approval,
        dependency_policy_refs,
        dependency_policy_status,
        rollback_proof_refs,
        rollback_readiness,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MODULE_INSTALL_DECISION_KIND.to_owned(),
            schema_id: Some(MODULE_INSTALL_DECISION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(MODULE_INSTALL_DECISION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_install_decision".to_owned(),
                uri: format!("module-install-decision:{decision_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module install decision resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        if state == "install_candidate" {
            "module_install.install_candidate_recorded"
        } else {
            "module_install.rejected"
        },
        &resource,
        json!({
            "installDecisionState": state,
            "metadataOnly": true,
            "installPerformed": false,
            "executionPerformed": false,
            "dependencyRestorePerformed": false,
            "approvalEvidenceIsAuthority": false,
            "derivedAuthorityRequired": true,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_DECISION_SCHEMA_VERSION,
        "operation": "module_install_decision_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleInstallDecisionResourceId": resource.resource_id,
        "moduleInstallDecisionVersionId": version_id,
        "installDecision": module_install_decision_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_install_decision")]
    }))
}

pub(crate) async fn list_module_install_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, "module_install_decision_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let lifecycle = optional_string(payload, "lifecycle")?
        .map(|value| bounded_token("lifecycle", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MODULE_INSTALL_DECISION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some("install_candidate".to_owned())
                }
            }),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut decisions = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_module_install_decision(&inspection, "module_install_decision_list")?;
        ensure_scope(&inspection, &scope, "module_install_decision_list")?;
        let (version, payload) = current_payload(&inspection, "module_install_decision_list")?;
        decisions.push(module_install_decision_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_DECISION_SCHEMA_VERSION,
        "operation": "module_install_decision_list",
        "scope": scope_ref(&scope),
        "installDecisions": decisions,
        "limits": {
            "requestedLimit": limit,
            "returned": decisions.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn inspect_module_install_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_install_decision_inspect").await?;
    let resource_id = required_string(payload, "moduleInstallDecisionResourceId")?;
    validate_module_install_decision_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_install_decision_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module install decision").await?;
    ensure_module_install_decision(&inspection, "module_install_decision_inspect")?;
    ensure_scope(&inspection, &scope, "module_install_decision_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_install_decision_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_INSTALL_DECISION_SCHEMA_VERSION,
        "operation": "module_install_decision_inspect",
        "scope": scope_ref(&scope),
        "installDecision": inspected_module_install_decision(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

async fn inspect_validation_prerequisite(
    deps: &Deps,
    resource_id: &str,
    scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, resource_id, "module validation report").await?;
    ensure_validation_report_prerequisite(&inspection, scope)
}
