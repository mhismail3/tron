use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceLocation, EngineResourceScope, Invocation, ListResources,
    UpdateResource,
};
use crate::shared::server::errors::CapabilityError;

use super::approval_gate::check_lifecycle_approval;
use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::MODULE_LIFECYCLE_STATE_SCHEMA_VERSION;
use super::payload_safety::reject_unsafe_payload;
use super::prerequisite::ensure_install_candidate_prerequisite;
use super::projection::{inspected_module_lifecycle, module_lifecycle_summary};
use super::records::{
    ModuleLifecycleRecordInput, module_lifecycle_record, module_lifecycle_resource_id,
    resource_policy, resource_ref, scope_ref, side_effect_proof, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_module_lifecycle_state, ensure_scope,
    inspect_resource_required, module_lifecycle_summary_for_resource, publish_lifecycle_event,
    worker_id,
};
use super::validation::*;
use super::{Deps, MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID};

pub(crate) async fn request_module_lifecycle_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "module_lifecycle_request").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let install_decision_resource_id = required_string(payload, "moduleInstallDecisionResourceId")?;
    validate_module_install_decision_resource_id(&install_decision_resource_id)?;
    let install_decision =
        inspect_install_candidate_prerequisite(deps, &install_decision_resource_id, &scope).await?;
    let action = lifecycle_action(payload)?;
    let state = "pending";
    let transition_id_input = optional_string(payload, "lifecycleTransitionId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let transition_id = bounded_provider_visible_token(
        "lifecycleTransitionId",
        &transition_id_input,
        TRANSITION_ID_MAX_BYTES,
    )?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let rollback_proof_refs = validate_ref_array(
        "rollbackProofRefs",
        &optional_array(payload, "rollbackProofRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let rollback_readiness = validate_rollback_readiness(payload)?;
    if action == "rollback"
        && (rollback_proof_refs.is_empty()
            || rollback_readiness.get("status").and_then(Value::as_str) != Some("ready"))
    {
        return Err(invalid(
            "module lifecycle rollback requires ready rollback proof refs",
        ));
    }
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let resource_id = module_lifecycle_resource_id(&scope, &install_decision_resource_id);
    require_exact_resource_selector(&grant, &resource_id, "module_lifecycle_request")?;
    let now = operation_at.to_rfc3339();

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_lifecycle_state(&existing, "module_lifecycle_request existing state")?;
        ensure_scope(&existing, &scope, "module_lifecycle_request existing state")?;
        let (current_version, current) =
            current_payload(&existing, "module_lifecycle_request existing state")?;
        let current_action = current
            .pointer("/transition/action")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("module lifecycle state is missing action"))?;
        if existing.resource.lifecycle == "pending" {
            if current_action == action {
                return Ok(json!({
                    "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
                    "operation": "module_lifecycle_request",
                    "status": existing.resource.lifecycle,
                    "idempotentReplay": true,
                    "moduleLifecycleResourceId": resource_id,
                    "moduleLifecycleVersionId": current_version.version_id,
                    "moduleLifecycle": module_lifecycle_summary(
                        &existing.resource,
                        current_version,
                        current
                    ),
                    "resourceRefs": [version_ref(
                        &existing.resource,
                        current_version,
                        "module_lifecycle_state"
                    )]
                }));
            }
            return Err(invalid(format!(
                "module lifecycle already has pending {current_action} transition; decide it before requesting {action}"
            )));
        }

        let record = module_lifecycle_record(ModuleLifecycleRecordInput {
            transition_id: &transition_id,
            action: &action,
            state,
            reason: &reason,
            scope: &scope,
            install_decision,
            previous_state: Some(existing.resource.lifecycle.as_str()),
            previous_version_id: Some(current_version.version_id.as_str()),
            approval: json!({
                "allowed": false,
                "reason": "approval pending",
                "approvalEvidenceOnly": true,
                "derivedAuthorityRequired": true,
                "rawAuthorityIdsStored": false
            }),
            rollback_proof_refs,
            rollback_readiness,
            evidence_refs,
            created_at: &now,
            updated_at: &now,
            invocation,
            idempotency_key: &idempotency_key,
            revision: current
                .get("revision")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .saturating_add(1),
        });
        let version = deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: Some(current_version.version_id.clone()),
                lifecycle: Some(state.to_owned()),
                payload: record,
                state: None,
                locations: vec![EngineResourceLocation {
                    kind: "module_lifecycle_state".to_owned(),
                    uri: format!("module-lifecycle-state:{resource_id}"),
                    mime_type: Some("application/json".to_owned()),
                    size_bytes: None,
                }],
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        let updated =
            inspect_resource_required(deps, &resource_id, "module lifecycle state").await?;
        publish_lifecycle_event(
            deps,
            invocation,
            "module_lifecycle.requested",
            &updated.resource,
            json!({
                "lifecycleAction": action,
                "previousLifecycleState": existing.resource.lifecycle,
                "previousVersionId": current_version.version_id,
                "metadataOnly": true,
                "activationPerformed": false,
                "executionPerformed": false,
                "rollbackExecuted": false,
                "networkPolicy": "none"
            }),
        )
        .await?;
        return Ok(json!({
            "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
            "operation": "module_lifecycle_request",
            "status": updated.resource.lifecycle,
            "idempotentReplay": false,
            "moduleLifecycleResourceId": resource_id,
            "moduleLifecycleVersionId": version.version_id,
            "moduleLifecycle": module_lifecycle_summary_for_resource(deps, &updated.resource).await?,
            "resourceRefs": [version_ref(&updated.resource, &version, "module_lifecycle_state")]
        }));
    }

    let record = module_lifecycle_record(ModuleLifecycleRecordInput {
        transition_id: &transition_id,
        action: &action,
        state,
        reason: &reason,
        scope: &scope,
        install_decision,
        previous_state: None,
        previous_version_id: None,
        approval: json!({
            "allowed": false,
            "reason": "approval pending",
            "approvalEvidenceOnly": true,
            "derivedAuthorityRequired": true,
            "rawAuthorityIdsStored": false
        }),
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
            kind: MODULE_LIFECYCLE_STATE_KIND.to_owned(),
            schema_id: Some(MODULE_LIFECYCLE_STATE_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_lifecycle_state".to_owned(),
                uri: format!("module-lifecycle-state:{transition_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module lifecycle resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_lifecycle.requested",
        &resource,
        json!({
            "lifecycleAction": action,
            "metadataOnly": true,
            "activationPerformed": false,
            "executionPerformed": false,
            "rollbackExecuted": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
        "operation": "module_lifecycle_request",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleLifecycleResourceId": resource.resource_id,
        "moduleLifecycleVersionId": version_id,
        "moduleLifecycle": module_lifecycle_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_lifecycle_state")]
    }))
}

pub(crate) async fn decide_module_lifecycle_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "module_lifecycle_decision").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let resource_id = required_string(payload, "moduleLifecycleResourceId")?;
    validate_module_lifecycle_state_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_lifecycle_decision")?;
    let expected_version_id = required_string(payload, "expectedModuleLifecycleVersionId")?;
    let decision = required_string(payload, "decision")?;
    if decision != "approved" {
        return Err(invalid(
            "module lifecycle decisions must be approved or denied by approval",
        ));
    }
    let inspection =
        inspect_resource_required(deps, &resource_id, "module lifecycle state").await?;
    ensure_module_lifecycle_state(&inspection, "module_lifecycle_decision")?;
    ensure_scope(&inspection, &scope, "module_lifecycle_decision")?;
    let (current_version, current) = current_payload(&inspection, "module_lifecycle_decision")?;
    if current_version.version_id != expected_version_id {
        return Err(invalid(format!(
            "module lifecycle current version conflict: expected {expected_version_id}, actual {}",
            current_version.version_id
        )));
    }
    let action = current
        .pointer("/transition/action")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("module lifecycle state is missing action"))?
        .to_owned();
    let target_state = target_state_for_action(&action);
    let install_decision_resource_id = current
        .pointer("/installDecision/resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("module lifecycle state is missing install decision ref"))?
        .to_owned();
    let install_decision =
        inspect_install_candidate_prerequisite(deps, &install_decision_resource_id, &scope).await?;
    let (approval_request_resource_id, approval_decision_resource_id) =
        validate_approval_refs(payload)?;
    let approval = check_lifecycle_approval(
        deps,
        &scope,
        &resource_id,
        &install_decision_resource_id,
        &action,
        &approval_request_resource_id,
        approval_decision_resource_id.as_deref(),
        operation_at,
    )
    .await?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let rollback_proof_refs = current
        .pointer("/rollback/proofRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let rollback_readiness = current
        .get("rollback")
        .cloned()
        .unwrap_or_else(|| json!({"status": "not_proven", "metadataOnly": true}));
    if action == "rollback"
        && (rollback_proof_refs.is_empty()
            || rollback_readiness.get("status").and_then(Value::as_str) != Some("ready"))
    {
        return Err(invalid(
            "module lifecycle rollback requires current ready rollback proof refs",
        ));
    }
    let evidence_refs = current
        .get("evidenceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let now = operation_at.to_rfc3339();
    let record = module_lifecycle_record(ModuleLifecycleRecordInput {
        transition_id: current
            .get("transitionId")
            .and_then(Value::as_str)
            .unwrap_or(invocation.id.as_str()),
        action: &action,
        state: target_state,
        reason: &reason,
        scope: &scope,
        install_decision,
        previous_state: Some(inspection.resource.lifecycle.as_str()),
        previous_version_id: Some(current_version.version_id.as_str()),
        approval,
        rollback_proof_refs,
        rollback_readiness,
        evidence_refs,
        created_at: current
            .get("createdAt")
            .and_then(Value::as_str)
            .unwrap_or(now.as_str()),
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: current
            .get("revision")
            .and_then(Value::as_u64)
            .unwrap_or(1)
            .saturating_add(1),
    });
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some(target_state.to_owned()),
            payload: record,
            state: None,
            locations: vec![EngineResourceLocation {
                kind: "module_lifecycle_state".to_owned(),
                uri: format!("module-lifecycle-state:{resource_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let updated = inspect_resource_required(deps, &resource_id, "module lifecycle state").await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_lifecycle.decided",
        &updated.resource,
        json!({
            "lifecycleAction": action,
            "lifecycleState": target_state,
            "metadataOnly": true,
            "activationPerformed": false,
            "executionPerformed": false,
            "rollbackExecuted": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
        "operation": "module_lifecycle_decision",
        "status": updated.resource.lifecycle,
        "idempotentReplay": false,
        "moduleLifecycleResourceId": resource_id,
        "moduleLifecycleVersionId": version.version_id,
        "moduleLifecycle": module_lifecycle_summary_for_resource(deps, &updated.resource).await?,
        "resourceRefs": [version_ref(&updated.resource, &version, "module_lifecycle_state")]
    }))
}

pub(crate) async fn list_module_lifecycle_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, "module_lifecycle_list").await?;
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
            kind: Some(MODULE_LIFECYCLE_STATE_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some("enabled".to_owned())
                }
            }),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut lifecycles = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_module_lifecycle_state(&inspection, "module_lifecycle_list")?;
        ensure_scope(&inspection, &scope, "module_lifecycle_list")?;
        let (version, payload) = current_payload(&inspection, "module_lifecycle_list")?;
        lifecycles.push(module_lifecycle_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
        "operation": "module_lifecycle_list",
        "scope": scope_ref(&scope),
        "moduleLifecycles": lifecycles,
        "limits": {
            "requestedLimit": limit,
            "returned": lifecycles.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn inspect_module_lifecycle_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_lifecycle_inspect").await?;
    let resource_id = required_string(payload, "moduleLifecycleResourceId")?;
    validate_module_lifecycle_state_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_lifecycle_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module lifecycle state").await?;
    ensure_module_lifecycle_state(&inspection, "module_lifecycle_inspect")?;
    ensure_scope(&inspection, &scope, "module_lifecycle_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_lifecycle_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
        "operation": "module_lifecycle_inspect",
        "scope": scope_ref(&scope),
        "moduleLifecycle": inspected_module_lifecycle(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

#[allow(dead_code)]
pub(crate) async fn ensure_runtime_allowed(
    deps: &Deps,
    scope: &EngineResourceScope,
    lifecycle_resource_id: &str,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, lifecycle_resource_id, "module lifecycle state").await?;
    ensure_module_lifecycle_state(&inspection, "module_runtime_authorization")?;
    ensure_scope(&inspection, scope, "module_runtime_authorization")?;
    let (version, payload) = current_payload(&inspection, "module_runtime_authorization")?;
    match inspection.resource.lifecycle.as_str() {
        "enabled" => Ok(json!({
            "allowed": true,
            "state": "enabled",
            "resourceId": inspection.resource.resource_id,
            "versionId": version.version_id,
            "runtimeAuthorization": payload.get("runtimeAuthorization").cloned().unwrap_or(Value::Null)
        })),
        "disabled" | "quarantined" | "rolled_back" => Err(invalid(format!(
            "module runtime denied fail-closed for lifecycle {}",
            inspection.resource.lifecycle
        ))),
        other => Err(invalid(format!(
            "module runtime denied fail-closed for non-enabled lifecycle {other}"
        ))),
    }
}

async fn inspect_install_candidate_prerequisite(
    deps: &Deps,
    resource_id: &str,
    scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, resource_id, "module install decision").await?;
    ensure_install_candidate_prerequisite(&inspection, scope)
}
