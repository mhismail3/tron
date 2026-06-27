use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceLocation, EngineResourceScope, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::{
    MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION, MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
    MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
};
use super::payload_safety::reject_unsafe_payload;
use super::projection::{
    inspected_module_dependency_decision, inspected_module_dependency_policy,
    inspected_module_dependency_request, module_dependency_decision_summary,
    module_dependency_policy_summary, module_dependency_request_summary,
};
use super::records::{
    ModuleDependencyDecisionInput, ModuleDependencyPolicyInput, ModuleDependencyRequestInput,
    module_dependency_decision_record, module_dependency_decision_resource_id,
    module_dependency_policy_record, module_dependency_policy_resource_id,
    module_dependency_request_record, module_dependency_request_resource_id, resource_policy,
    resource_ref, scope_ref, side_effect_proof, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_module_dependency_decision,
    ensure_module_dependency_policy, ensure_module_dependency_request, ensure_scope,
    inspect_resource_required, module_dependency_decision_summary_for_resource,
    module_dependency_policy_summary_for_resource, module_dependency_request_summary_for_resource,
    publish_lifecycle_event, worker_id,
};
use super::validation::*;
use super::{
    Deps, MODULE_DEPENDENCY_DECISION_KIND, MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
    MODULE_DEPENDENCY_POLICY_KIND, MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
    MODULE_DEPENDENCY_REQUEST_KIND, MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
};

pub(crate) async fn record_module_dependency_request_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "module_dependency_request_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_id_input = optional_string(payload, "dependencyRequestId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let request_id = bounded_provider_visible_token(
        "dependencyRequestId",
        &request_id_input,
        REQUEST_ID_MAX_BYTES,
    )?;
    let state = request_lifecycle_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let module_ref = required_ref(payload, "moduleRef")?;
    let proposal_ref = optional_ref(payload, "proposalRef")?;
    let validation_ref = optional_ref(payload, "validationRef")?;
    let install_ref = optional_ref(payload, "installRef")?;
    let runtime_ref = optional_ref(payload, "runtimeRef")?;
    let dependency_name = bounded_provider_visible_token(
        "dependencyName",
        &required_string(payload, "dependencyName")?,
        TOKEN_MAX_BYTES,
    )?;
    let dependency_version_req = optional_string(payload, "dependencyVersionReq")?
        .map(|value| bounded_text("dependencyVersionReq", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let ecosystem = bounded_provider_visible_token(
        "dependencyEcosystem",
        &required_string(payload, "dependencyEcosystem")?,
        TOKEN_MAX_BYTES,
    )?;
    let rationale = bounded_text(
        "rationale",
        &required_string(payload, "rationale")?,
        SUMMARY_MAX_BYTES,
    )?;
    let security_need = bounded_text(
        "securityNeed",
        &required_string(payload, "securityNeed")?,
        SUMMARY_MAX_BYTES,
    )?;
    let license_need = bounded_text(
        "licenseNeed",
        &required_string(payload, "licenseNeed")?,
        SUMMARY_MAX_BYTES,
    )?;
    let runtime_need = bounded_text(
        "runtimeNeed",
        &required_string(payload, "runtimeNeed")?,
        SUMMARY_MAX_BYTES,
    )?;
    let removal_plan = bounded_text(
        "removalPlan",
        &required_string(payload, "removalPlan")?,
        SUMMARY_MAX_BYTES,
    )?;
    let risk_class = risk_class(payload)?;
    let review_status = review_status(payload)?;
    let cargo_toml_evidence = parity_evidence(payload, "cargoTomlEvidence")?;
    let cargo_lock_evidence = parity_evidence(payload, "cargoLockEvidence")?;
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let now = operation_at.to_rfc3339();
    let resource_id = module_dependency_request_resource_id(&scope, &request_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_dependency_request(&existing, "module_dependency_request_record replay")?;
        ensure_scope(&existing, &scope, "module_dependency_request_record replay")?;
        let (version, payload) =
            current_payload(&existing, "module_dependency_request_record replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
            "operation": "module_dependency_request_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleDependencyRequestResourceId": resource_id,
            "moduleDependencyRequestVersionId": version.version_id,
            "dependencyRequest": module_dependency_request_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_dependency_request")]
        }));
    }

    let record = module_dependency_request_record(ModuleDependencyRequestInput {
        request_id: &request_id,
        state: &state,
        scope: &scope,
        title: &title,
        module_ref,
        proposal_ref,
        validation_ref,
        install_ref,
        runtime_ref,
        dependency_name: &dependency_name,
        dependency_version_req: dependency_version_req.as_deref(),
        ecosystem: &ecosystem,
        rationale: &rationale,
        security_need: &security_need,
        license_need: &license_need,
        runtime_need: &runtime_need,
        removal_plan: &removal_plan,
        risk_class: &risk_class,
        review_status: &review_status,
        cargo_toml_evidence,
        cargo_lock_evidence,
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
            kind: MODULE_DEPENDENCY_REQUEST_KIND.to_owned(),
            schema_id: Some(MODULE_DEPENDENCY_REQUEST_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(MODULE_DEPENDENCY_REQUEST_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_dependency_request".to_owned(),
                uri: format!("module-dependency-request:{request_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module dependency request resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_dependency.request_recorded",
        &resource,
        json!({
            "dependencyRequestState": state,
            "metadataOnly": true,
            "reviewRequired": true,
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "manifestMutated": false,
            "lockfileMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
        "operation": "module_dependency_request_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleDependencyRequestResourceId": resource.resource_id,
        "moduleDependencyRequestVersionId": version_id,
        "dependencyRequest": module_dependency_request_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_dependency_request")]
    }))
}

pub(crate) async fn list_module_dependency_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "module_dependency_request_list",
        MODULE_DEPENDENCY_REQUEST_KIND,
        "pending_review",
        |resource, version, payload| module_dependency_request_summary(resource, version, payload),
        "dependencyRequests",
    )
    .await
}

pub(crate) async fn inspect_module_dependency_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_dependency_request_inspect").await?;
    let resource_id = required_string(payload, "moduleDependencyRequestResourceId")?;
    validate_module_dependency_request_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_dependency_request_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module dependency request").await?;
    ensure_module_dependency_request(&inspection, "module_dependency_request_inspect")?;
    ensure_scope(&inspection, &scope, "module_dependency_request_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_dependency_request_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
        "operation": "module_dependency_request_inspect",
        "scope": scope_ref(&scope),
        "dependencyRequest": inspected_module_dependency_request(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn record_module_dependency_decision_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_write_authority(deps, invocation, "module_dependency_decision_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let decision_id_input = optional_string(payload, "dependencyDecisionId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let decision_id = bounded_provider_visible_token(
        "dependencyDecisionId",
        &decision_id_input,
        DECISION_ID_MAX_BYTES,
    )?;
    let request_resource_id = required_string(payload, "moduleDependencyRequestResourceId")?;
    validate_module_dependency_request_resource_id(&request_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &request_resource_id,
        "module_dependency_decision_record",
    )?;
    let request_inspection =
        inspect_resource_required(deps, &request_resource_id, "module dependency request").await?;
    ensure_module_dependency_request(&request_inspection, "module_dependency_decision_record")?;
    ensure_scope(
        &request_inspection,
        &scope,
        "module_dependency_decision_record",
    )?;
    let (request_version, request_payload) =
        current_payload(&request_inspection, "module_dependency_decision_record")?;
    let state = decision_lifecycle_state(payload)?;
    let decision = required_string(payload, "decision")?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let risk_class = request_payload
        .pointer("/needs/riskClass")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("module dependency request is missing riskClass"))?
        .to_owned();
    let review_status = if state == "approved_policy" {
        "approved"
    } else {
        "denied"
    };
    let denial_evidence = validate_ref_array(
        "denialEvidence",
        &optional_array(payload, "denialEvidence")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if state == "rejected" && denial_evidence.is_empty() {
        return Err(invalid(
            "module dependency rejected decisions require denialEvidence",
        ));
    }
    if matches!(risk_class.as_str(), "high" | "critical")
        && state == "rejected"
        && denial_evidence.is_empty()
    {
        return Err(invalid(
            "high-risk module dependency denials require denialEvidence",
        ));
    }
    let now = operation_at.to_rfc3339();
    let resource_id =
        module_dependency_decision_resource_id(&scope, &decision_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_dependency_decision(&existing, "module_dependency_decision_record replay")?;
        ensure_scope(
            &existing,
            &scope,
            "module_dependency_decision_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "module_dependency_decision_record replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION,
            "operation": "module_dependency_decision_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleDependencyDecisionResourceId": resource_id,
            "moduleDependencyDecisionVersionId": version.version_id,
            "dependencyDecision": module_dependency_decision_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_dependency_decision")]
        }));
    }

    let record = module_dependency_decision_record(ModuleDependencyDecisionInput {
        decision_id: &decision_id,
        state: &state,
        decision: &decision,
        reason: &reason,
        risk_class: &risk_class,
        review_status,
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
            kind: MODULE_DEPENDENCY_DECISION_KIND.to_owned(),
            schema_id: Some(MODULE_DEPENDENCY_DECISION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(MODULE_DEPENDENCY_DECISION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_dependency_decision".to_owned(),
                uri: format!("module-dependency-decision:{decision_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module dependency decision resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        if state == "approved_policy" {
            "module_dependency.policy_candidate_recorded"
        } else {
            "module_dependency.rejected"
        },
        &resource,
        json!({
            "dependencyDecisionState": state,
            "metadataOnly": true,
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "manifestMutated": false,
            "lockfileMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION,
        "operation": "module_dependency_decision_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleDependencyDecisionResourceId": resource.resource_id,
        "moduleDependencyDecisionVersionId": version_id,
        "dependencyDecision": module_dependency_decision_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_dependency_decision")]
    }))
}

pub(crate) async fn list_module_dependency_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "module_dependency_decision_list",
        MODULE_DEPENDENCY_DECISION_KIND,
        "approved_policy",
        |resource, version, payload| module_dependency_decision_summary(resource, version, payload),
        "dependencyDecisions",
    )
    .await
}

pub(crate) async fn inspect_module_dependency_decision_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_dependency_decision_inspect").await?;
    let resource_id = required_string(payload, "moduleDependencyDecisionResourceId")?;
    validate_module_dependency_decision_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_dependency_decision_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module dependency decision").await?;
    ensure_module_dependency_decision(&inspection, "module_dependency_decision_inspect")?;
    ensure_scope(&inspection, &scope, "module_dependency_decision_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_dependency_decision_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION,
        "operation": "module_dependency_decision_inspect",
        "scope": scope_ref(&scope),
        "dependencyDecision": inspected_module_dependency_decision(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn activate_module_dependency_policy_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_write_authority(deps, invocation, "module_dependency_policy_activate").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let policy_id_input = optional_string(payload, "dependencyPolicyId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let policy_id = bounded_provider_visible_token(
        "dependencyPolicyId",
        &policy_id_input,
        POLICY_ID_MAX_BYTES,
    )?;
    let decision_resource_id = required_string(payload, "moduleDependencyDecisionResourceId")?;
    validate_module_dependency_decision_resource_id(&decision_resource_id)?;
    require_exact_resource_selector(
        &grant,
        &decision_resource_id,
        "module_dependency_policy_activate",
    )?;
    let decision_inspection =
        inspect_resource_required(deps, &decision_resource_id, "module dependency decision")
            .await?;
    ensure_module_dependency_decision(&decision_inspection, "module_dependency_policy_activate")?;
    ensure_scope(
        &decision_inspection,
        &scope,
        "module_dependency_policy_activate",
    )?;
    if decision_inspection.resource.lifecycle != "approved_policy" {
        return Err(invalid(
            "module dependency policy activation requires an approved_policy decision",
        ));
    }
    let (decision_version, decision_payload) =
        current_payload(&decision_inspection, "module_dependency_policy_activate")?;
    let state = policy_lifecycle_state(payload)?;
    let activation_reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let resource_id = module_dependency_policy_resource_id(
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
        ensure_module_dependency_policy(&existing, "module_dependency_policy_activate replay")?;
        ensure_scope(
            &existing,
            &scope,
            "module_dependency_policy_activate replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "module_dependency_policy_activate replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
            "operation": "module_dependency_policy_activate",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleDependencyPolicyResourceId": resource_id,
            "moduleDependencyPolicyVersionId": version.version_id,
            "dependencyPolicy": module_dependency_policy_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_dependency_policy")]
        }));
    }

    let now = operation_at.to_rfc3339();
    let record = module_dependency_policy_record(ModuleDependencyPolicyInput {
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
            kind: MODULE_DEPENDENCY_POLICY_KIND.to_owned(),
            schema_id: Some(MODULE_DEPENDENCY_POLICY_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(MODULE_DEPENDENCY_POLICY_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_dependency_policy".to_owned(),
                uri: format!("module-dependency-policy:{policy_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid("module dependency policy resource was created without a current version")
    })?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_dependency.policy_activated",
        &resource,
        json!({
            "dependencyPolicyState": state,
            "approvedMetadataPolicyAvailable": true,
            "metadataOnly": true,
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "manifestMutated": false,
            "lockfileMutated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
        "operation": "module_dependency_policy_activate",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleDependencyPolicyResourceId": resource.resource_id,
        "moduleDependencyPolicyVersionId": version_id,
        "dependencyPolicy": module_dependency_policy_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_dependency_policy")]
    }))
}

pub(crate) async fn list_module_dependency_policy_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "module_dependency_policy_list",
        MODULE_DEPENDENCY_POLICY_KIND,
        "active",
        |resource, version, payload| module_dependency_policy_summary(resource, version, payload),
        "dependencyPolicies",
    )
    .await
}

pub(crate) async fn inspect_module_dependency_policy_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_dependency_policy_inspect").await?;
    let resource_id = required_string(payload, "moduleDependencyPolicyResourceId")?;
    validate_module_dependency_policy_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_dependency_policy_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection =
        inspect_resource_required(deps, &resource_id, "module dependency policy").await?;
    ensure_module_dependency_policy(&inspection, "module_dependency_policy_inspect")?;
    ensure_scope(&inspection, &scope, "module_dependency_policy_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_dependency_policy_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
        "operation": "module_dependency_policy_inspect",
        "scope": scope_ref(&scope),
        "dependencyPolicy": inspected_module_dependency_policy(&inspection.resource, version, payload),
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
            MODULE_DEPENDENCY_REQUEST_KIND => {
                ensure_module_dependency_request(&inspection, operation)?
            }
            MODULE_DEPENDENCY_DECISION_KIND => {
                ensure_module_dependency_decision(&inspection, operation)?
            }
            MODULE_DEPENDENCY_POLICY_KIND => {
                ensure_module_dependency_policy(&inspection, operation)?
            }
            _ => return Err(invalid("unsupported module dependency resource kind")),
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

fn schema_for_kind(kind: &str) -> &'static str {
    match kind {
        MODULE_DEPENDENCY_REQUEST_KIND => MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
        MODULE_DEPENDENCY_DECISION_KIND => MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION,
        MODULE_DEPENDENCY_POLICY_KIND => MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
        _ => "tron.module_dependency.unknown",
    }
}

#[allow(dead_code)]
fn _scope_for_docs(_: &EngineResourceScope) {}
