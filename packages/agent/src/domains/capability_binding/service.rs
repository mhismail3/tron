use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{CreateResource, EngineResourceLocation, Invocation, ListResources};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::{
    CAPABILITY_BINDING_DECISION_SCHEMA_VERSION, CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
    CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
};
use super::payload_safety::reject_unsafe_payload;
use super::projection::{
    capability_binding_decision_summary, capability_binding_policy_summary,
    capability_binding_request_summary, inspected_capability_binding_decision,
    inspected_capability_binding_policy, inspected_capability_binding_request,
};
use super::records::{
    CapabilityBindingDecisionInput, CapabilityBindingPolicyInput, CapabilityBindingRequestInput,
    capability_binding_decision_record, capability_binding_decision_resource_id,
    capability_binding_policy_record, capability_binding_policy_resource_id,
    capability_binding_request_record, capability_binding_request_resource_id, resource_policy,
    resource_ref, scope_ref, side_effect_proof, version_ref,
};
use super::resource_store::{
    capability_binding_decision_summary_for_resource,
    capability_binding_policy_summary_for_resource,
    capability_binding_request_summary_for_resource, current_payload, engine_error,
    ensure_capability_binding_decision, ensure_capability_binding_policy,
    ensure_capability_binding_request, ensure_scope, inspect_resource_required,
    publish_lifecycle_event, worker_id,
};
use super::validation::*;
use super::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_DECISION_SCHEMA_ID,
    CAPABILITY_BINDING_POLICY_KIND, CAPABILITY_BINDING_POLICY_SCHEMA_ID,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_BINDING_REQUEST_SCHEMA_ID, Deps,
};

pub(crate) async fn record_capability_binding_request_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "capability_binding_request_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_id_input = optional_string(payload, "capabilityBindingRequestId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let request_id = bounded_provider_visible_token(
        "capabilityBindingRequestId",
        &request_id_input,
        REQUEST_ID_MAX_BYTES,
    )?;
    let state = request_lifecycle_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let target_metadata = target_operation_binding_metadata(payload)?;
    let binding_mode = binding_mode(payload)?;
    let replacement_target = replacement_target(payload)?;
    if replacement_target != target_metadata.replacement_target {
        return Err(invalid(format!(
            "replacementTarget mismatch for {}: expected {}",
            target_metadata.operation_name, target_metadata.replacement_target
        )));
    }
    let target_ref = required_ref(payload, "targetRef")?;
    let actor_scope = actor_scope(payload)?;
    let rationale = bounded_text(
        "rationale",
        &required_string(payload, "rationale")?,
        SUMMARY_MAX_BYTES,
    )?;
    let contract_requirements = contract_requirements(payload)?;
    let authority_constraints = authority_constraints(payload)?;
    let stale_version_guard = stale_version_guard(payload)?;
    let rollback_ref = optional_ref(payload, "rollbackRef")?;
    let disable_ref = optional_ref(payload, "disableRef")?;
    ensure_binding_mode_allowed(
        &target_metadata.ownership_class,
        &binding_mode,
        &rollback_ref,
    )?;
    let audit_refs = validate_ref_array(
        "auditRefs",
        &optional_array(payload, "auditRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let now = operation_at.to_rfc3339();
    let resource_id = capability_binding_request_resource_id(&scope, &request_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_binding_request(&existing, "capability_binding_request_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_binding_request_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_binding_request_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
            "operation": "capability_binding_request_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityBindingRequestResourceId": resource_id,
            "capabilityBindingRequestVersionId": version.version_id,
            "bindingRequest": capability_binding_request_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_binding_request")]
        }));
    }

    let record = capability_binding_request_record(CapabilityBindingRequestInput {
        request_id: &request_id,
        state: &state,
        scope: &scope,
        title: &title,
        operation_name: &target_metadata.operation_name,
        current_owner: &target_metadata.current_owner,
        ownership_class: &target_metadata.ownership_class,
        replacement_target: &target_metadata.replacement_target,
        binding_mode: &binding_mode,
        target_ref,
        actor_scope: &actor_scope,
        rationale: &rationale,
        contract_requirements,
        authority_constraints,
        stale_version_guard,
        rollback_ref,
        disable_ref,
        audit_refs,
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
            kind: CAPABILITY_BINDING_REQUEST_KIND.to_owned(),
            schema_id: Some(CAPABILITY_BINDING_REQUEST_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(CAPABILITY_BINDING_REQUEST_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "capability_binding_request".to_owned(),
                uri: format!("capability-binding-request:{request_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability binding request resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "capability_binding.request_recorded",
        &resource,
        json!({
            "bindingRequestState": state,
            "targetOperation": target_metadata.operation_name,
            "ownershipClass": target_metadata.ownership_class,
            "bindingMode": binding_mode,
            "metadataOnly": true,
            "reviewRequired": true,
            "runtimeRoutingChanged": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
        "operation": "capability_binding_request_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityBindingRequestResourceId": resource.resource_id,
        "capabilityBindingRequestVersionId": version_id,
        "bindingRequest": capability_binding_request_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_binding_request")]
    }))
}

pub(crate) async fn list_capability_binding_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "capability_binding_request_list",
        CAPABILITY_BINDING_REQUEST_KIND,
        "pending_review",
        capability_binding_request_summary,
        "bindingRequests",
    )
    .await
}

pub(crate) async fn inspect_capability_binding_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "capability_binding_request_inspect").await?;
    let resource_id = required_string(payload, "capabilityBindingRequestResourceId")?;
    validate_capability_binding_request_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "capability_binding_request_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "capability binding request").await?;
    ensure_capability_binding_request(&inspection, "capability_binding_request_inspect")?;
    ensure_scope(&inspection, &scope, "capability_binding_request_inspect")?;
    let (version, payload) = current_payload(&inspection, "capability_binding_request_inspect")?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
        "operation": "capability_binding_request_inspect",
        "scope": scope_ref(&scope),
        "bindingRequest": inspected_capability_binding_request(&inspection.resource, version, payload),
        "history": history_summary(&inspection),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn record_capability_binding_decision_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_write_authority(deps, invocation, "capability_binding_decision_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let decision_id_input = optional_string(payload, "capabilityBindingDecisionId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let decision_id = bounded_provider_visible_token(
        "capabilityBindingDecisionId",
        &decision_id_input,
        DECISION_ID_MAX_BYTES,
    )?;
    let request_resource_id = required_string(payload, "capabilityBindingRequestResourceId")?;
    validate_capability_binding_request_resource_id(&request_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &request_resource_id,
        "capability_binding_decision_record",
    )?;
    let request_inspection =
        inspect_resource_required(deps, &request_resource_id, "capability binding request").await?;
    ensure_capability_binding_request(&request_inspection, "capability_binding_decision_record")?;
    ensure_scope(
        &request_inspection,
        &scope,
        "capability_binding_decision_record",
    )?;
    let (request_version, request_payload) =
        current_payload(&request_inspection, "capability_binding_decision_record")?;
    let expected_version = required_string(payload, "expectedCapabilityBindingRequestVersionId")?;
    if expected_version != request_version.version_id {
        return Err(invalid(format!(
            "stale capability binding request version {expected_version}"
        )));
    }
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
            "capability binding rejected decisions require denialEvidence",
        ));
    }
    let now = operation_at.to_rfc3339();
    let resource_id =
        capability_binding_decision_resource_id(&scope, &decision_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_binding_decision(&existing, "capability_binding_decision_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_binding_decision_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_binding_decision_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_BINDING_DECISION_SCHEMA_VERSION,
            "operation": "capability_binding_decision_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityBindingDecisionResourceId": resource_id,
            "capabilityBindingDecisionVersionId": version.version_id,
            "bindingDecision": capability_binding_decision_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_binding_decision")]
        }));
    }

    let record = capability_binding_decision_record(CapabilityBindingDecisionInput {
        decision_id: &decision_id,
        state: &state,
        decision: &decision,
        reason: &reason,
        denial_evidence,
        request_resource: &request_inspection.resource,
        request_version,
        request_payload,
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
            kind: CAPABILITY_BINDING_DECISION_KIND.to_owned(),
            schema_id: Some(CAPABILITY_BINDING_DECISION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(CAPABILITY_BINDING_DECISION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "capability_binding_decision".to_owned(),
                uri: format!("capability-binding-decision:{decision_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability binding decision resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        if state == "approved_policy" {
            "capability_binding.policy_candidate_recorded"
        } else {
            "capability_binding.rejected"
        },
        &resource,
        json!({
            "bindingDecisionState": state,
            "metadataOnly": true,
            "runtimeRoutingChanged": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_DECISION_SCHEMA_VERSION,
        "operation": "capability_binding_decision_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityBindingDecisionResourceId": resource.resource_id,
        "capabilityBindingDecisionVersionId": version_id,
        "bindingDecision": capability_binding_decision_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_binding_decision")]
    }))
}

pub(crate) async fn list_capability_binding_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "capability_binding_decision_list",
        CAPABILITY_BINDING_DECISION_KIND,
        "approved_policy",
        capability_binding_decision_summary,
        "bindingDecisions",
    )
    .await
}

pub(crate) async fn inspect_capability_binding_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "capability_binding_decision_inspect").await?;
    let resource_id = required_string(payload, "capabilityBindingDecisionResourceId")?;
    validate_capability_binding_decision_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "capability_binding_decision_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "capability binding decision").await?;
    ensure_capability_binding_decision(&inspection, "capability_binding_decision_inspect")?;
    ensure_scope(&inspection, &scope, "capability_binding_decision_inspect")?;
    let (version, payload) = current_payload(&inspection, "capability_binding_decision_inspect")?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_DECISION_SCHEMA_VERSION,
        "operation": "capability_binding_decision_inspect",
        "scope": scope_ref(&scope),
        "bindingDecision": inspected_capability_binding_decision(&inspection.resource, version, payload),
        "history": history_summary(&inspection),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn activate_capability_binding_policy_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_write_authority(deps, invocation, "capability_binding_policy_activate").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let policy_id_input = optional_string(payload, "capabilityBindingPolicyId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let policy_id = bounded_provider_visible_token(
        "capabilityBindingPolicyId",
        &policy_id_input,
        POLICY_ID_MAX_BYTES,
    )?;
    let decision_resource_id = required_string(payload, "capabilityBindingDecisionResourceId")?;
    validate_capability_binding_decision_resource_id(&decision_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &decision_resource_id,
        "capability_binding_policy_activate",
    )?;
    let decision_inspection =
        inspect_resource_required(deps, &decision_resource_id, "capability binding decision")
            .await?;
    ensure_capability_binding_decision(&decision_inspection, "capability_binding_policy_activate")?;
    ensure_scope(
        &decision_inspection,
        &scope,
        "capability_binding_policy_activate",
    )?;
    if decision_inspection.resource.lifecycle != "approved_policy" {
        return Err(invalid(
            "capability binding policy activation requires an approved_policy decision",
        ));
    }
    let (decision_version, decision_payload) =
        current_payload(&decision_inspection, "capability_binding_policy_activate")?;
    let expected_version = required_string(payload, "expectedCapabilityBindingDecisionVersionId")?;
    if expected_version != decision_version.version_id {
        return Err(invalid(format!(
            "stale capability binding decision version {expected_version}"
        )));
    }
    let state = policy_lifecycle_state(payload)?;
    let activation_reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let resource_id = capability_binding_policy_resource_id(
        &scope,
        &policy_id,
        &decision_resource_id,
        &idempotency_key,
    );

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_binding_policy(&existing, "capability_binding_policy_activate replay")?;
        ensure_scope(
            &existing,
            &scope,
            "capability_binding_policy_activate replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_binding_policy_activate replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
            "operation": "capability_binding_policy_activate",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityBindingPolicyResourceId": resource_id,
            "capabilityBindingPolicyVersionId": version.version_id,
            "bindingPolicy": capability_binding_policy_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_binding_policy")]
        }));
    }

    let now = operation_at.to_rfc3339();
    let record = capability_binding_policy_record(CapabilityBindingPolicyInput {
        policy_id: &policy_id,
        state: &state,
        activation_reason: &activation_reason,
        decision_resource: &decision_inspection.resource,
        decision_version,
        decision_payload,
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
            kind: CAPABILITY_BINDING_POLICY_KIND.to_owned(),
            schema_id: Some(CAPABILITY_BINDING_POLICY_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(CAPABILITY_BINDING_POLICY_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "capability_binding_policy".to_owned(),
                uri: format!("capability-binding-policy:{policy_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("capability binding policy resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "capability_binding.policy_activated",
        &resource,
        json!({
            "bindingPolicyState": state,
            "approvedMetadataPolicyAvailable": true,
            "metadataOnly": true,
            "runtimeRoutingChanged": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
        "operation": "capability_binding_policy_activate",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityBindingPolicyResourceId": resource.resource_id,
        "capabilityBindingPolicyVersionId": version_id,
        "bindingPolicy": capability_binding_policy_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_binding_policy")]
    }))
}

pub(crate) async fn list_capability_binding_policy_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "capability_binding_policy_list",
        CAPABILITY_BINDING_POLICY_KIND,
        "active",
        capability_binding_policy_summary,
        "bindingPolicies",
    )
    .await
}

pub(crate) async fn inspect_capability_binding_policy_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "capability_binding_policy_inspect").await?;
    let resource_id = required_string(payload, "capabilityBindingPolicyResourceId")?;
    validate_capability_binding_policy_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "capability_binding_policy_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "capability binding policy").await?;
    ensure_capability_binding_policy(&inspection, "capability_binding_policy_inspect")?;
    ensure_scope(&inspection, &scope, "capability_binding_policy_inspect")?;
    let (version, payload) = current_payload(&inspection, "capability_binding_policy_inspect")?;
    Ok(json!({
        "schemaVersion": CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
        "operation": "capability_binding_policy_inspect",
        "scope": scope_ref(&scope),
        "bindingPolicy": inspected_capability_binding_policy(&inspection.resource, version, payload),
        "history": history_summary(&inspection),
        "sideEffects": side_effect_proof()
    }))
}

async fn list_values(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    kind: &str,
    default_lifecycle: &str,
    summary: fn(
        &crate::engine::EngineResource,
        &crate::engine::EngineResourceVersion,
        &Value,
    ) -> Value,
    output_key: &str,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, operation).await?;
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
            kind: Some(kind.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some(default_lifecycle.to_owned())
                }
            }),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut items = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        match kind {
            CAPABILITY_BINDING_REQUEST_KIND => {
                ensure_capability_binding_request(&inspection, operation)?
            }
            CAPABILITY_BINDING_DECISION_KIND => {
                ensure_capability_binding_decision(&inspection, operation)?
            }
            CAPABILITY_BINDING_POLICY_KIND => {
                ensure_capability_binding_policy(&inspection, operation)?
            }
            _ => return Err(invalid("unsupported capability binding resource kind")),
        }
        ensure_scope(&inspection, &scope, operation)?;
        let (version, payload) = current_payload(&inspection, operation)?;
        items.push(summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": schema_for_kind(kind),
        "operation": operation,
        "scope": scope_ref(&scope),
        output_key: items,
        "limits": {
            "requestedLimit": limit,
            "returned": items.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

fn history_summary(inspection: &crate::engine::EngineResourceInspection) -> Value {
    json!({
        "resourceEvents": inspection.events.len(),
        "versions": inspection.versions.len(),
        "currentVersionId": inspection.resource.current_version_id.as_deref(),
        "auditBackedByResourceEvents": true
    })
}

fn schema_for_kind(kind: &str) -> &'static str {
    match kind {
        CAPABILITY_BINDING_REQUEST_KIND => CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
        CAPABILITY_BINDING_DECISION_KIND => CAPABILITY_BINDING_DECISION_SCHEMA_VERSION,
        CAPABILITY_BINDING_POLICY_KIND => CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
        _ => "tron.capability_binding.unknown",
    }
}
