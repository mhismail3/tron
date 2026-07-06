use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineGrant, EngineResource, EngineResourceInspection, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_route_write_authority, inspect_route_read_grant, require_exact_resource_selector,
};
use super::contract::{
    CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION, CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION,
    CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION, CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION,
    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_VERSION, WORKER, WRITE_SCOPE,
};
use super::payload_safety::reject_unsafe_payload;
use super::records::{
    idempotency_evidence, resource_ref, scope_ref, stable_resource_id, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_capability_replacement_candidate,
    ensure_capability_route_activation, ensure_capability_route_binding,
    ensure_capability_route_event, ensure_capability_route_rollback,
    ensure_capability_shadow_trial_evidence, ensure_scope, inspect_resource_required,
    publish_lifecycle_event, worker_id,
};
use super::validation::{
    DECISION_ID_MAX_BYTES, LIST_LIMIT_DEFAULT, LIST_LIMIT_MAX, MAX_REFS, REQUEST_ID_MAX_BYTES,
    SUMMARY_MAX_BYTES, TOKEN_MAX_BYTES, authority_constraints, bounded_provider_visible_token,
    bounded_text, idempotency_key, invalid, optional_array, optional_string, optional_u64,
    required_ref, required_string, resource_scope, target_operation_binding_metadata,
    validate_ref_array,
};
use super::{
    CAPABILITY_REPLACEMENT_CANDIDATE_KIND, CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
    CAPABILITY_ROUTE_ACTIVATION_KIND, CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
    CAPABILITY_ROUTE_BINDING_KIND, CAPABILITY_ROUTE_BINDING_SCHEMA_ID, CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_EVENT_SCHEMA_ID, CAPABILITY_ROUTE_ROLLBACK_KIND,
    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND, Deps,
};

const TARGET_OPERATION: &str = "git_status";
const CANDIDATE_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_replacement_candidate.idempotency.v1";
const ROUTE_BINDING_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_route_binding.idempotency.v1";
const ROUTE_ACTIVATION_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_route_activation.idempotency.v1";
const ROUTE_EVENT_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_route_event.idempotency.v1";
const ROUTE_ROLLBACK_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_route_rollback.idempotency.v1";
const CANDIDATE_IDEMPOTENCY_DOMAIN: &[u8] =
    b"tron.capability_replacement_candidate.idempotency.v1\0";
const ROUTE_BINDING_IDEMPOTENCY_DOMAIN: &[u8] = b"tron.capability_route_binding.idempotency.v1\0";
const ROUTE_ACTIVATION_IDEMPOTENCY_DOMAIN: &[u8] =
    b"tron.capability_route_activation.idempotency.v1\0";
const ROUTE_EVENT_IDEMPOTENCY_DOMAIN: &[u8] = b"tron.capability_route_event.idempotency.v1\0";
const ROUTE_ROLLBACK_IDEMPOTENCY_DOMAIN: &[u8] = b"tron.capability_route_rollback.idempotency.v1\0";

#[derive(Clone, Debug)]
pub(crate) struct ActiveRoute {
    pub(crate) activation_resource_id: String,
    pub(crate) activation_version_id: String,
    pub(crate) route_version: String,
    pub(crate) candidate_owner: String,
    pub(crate) candidate_label: String,
}

pub(crate) async fn record_replacement_candidate_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_route_write_authority(deps, invocation, "capability_replacement_candidate_record")
            .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let candidate_id = bounded_provider_visible_token(
        "capabilityReplacementCandidateId",
        &optional_string(payload, "capabilityReplacementCandidateId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
        REQUEST_ID_MAX_BYTES,
    )?;
    let state = route_state(
        payload,
        "lifecycleState",
        &["validated", "rejected", "disabled"],
    )?;
    let operation = route_target_metadata(payload)?;
    let shadow_evidence = validated_shadow_evidence_from_payload(
        deps,
        Some(&grant),
        &scope,
        payload,
        "capability_replacement_candidate_record",
    )
    .await?;
    let candidate = candidate_contract(payload, shadow_evidence)?;
    let contract = contract_evidence(payload)?;
    let authority = route_authority(payload)?;
    let rollback = rollback_controls(payload)?;
    let audit_refs = safe_refs(payload, "auditRefs")?;
    let now = operation_at.to_rfc3339();
    let resource_id = route_resource_id(
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        &scope,
        &candidate_id,
        &idempotency_key,
    );
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_replacement_candidate(
            &existing,
            "capability_replacement_candidate_record replay",
        )?;
        ensure_scope(
            &existing,
            &scope,
            "capability_replacement_candidate_record replay",
        )?;
        let (version, payload) =
            current_payload(&existing, "capability_replacement_candidate_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION,
            "operation": "capability_replacement_candidate_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityReplacementCandidateResourceId": resource_id,
            "capabilityReplacementCandidateVersionId": version.version_id,
            "replacementCandidate": route_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_replacement_candidate")]
        }));
    }
    let record = json!({
        "schemaVersion": CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION,
        "state": state,
        "candidateId": candidate_id,
        "scope": scope_ref(&scope),
        "operation": operation,
        "candidate": candidate,
        "contract": contract,
        "authority": authority,
        "rollback": rollback,
        "auditRefs": audit_refs,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "idempotency": idempotency_evidence(&idempotency_key, CANDIDATE_IDEMPOTENCY_FINGERPRINT_ALGORITHM, CANDIDATE_IDEMPOTENCY_DOMAIN),
        "sideEffectProof": route_side_effect(false),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = create_route_resource(
        deps,
        invocation,
        resource_id.clone(),
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
        &scope,
        &state,
        "capability-replacement-candidate",
        &candidate_id,
        record,
    )
    .await?;
    let version_id = current_version_id(&resource, "capability_replacement_candidate_record")?;
    publish_lifecycle_event(
        deps,
        invocation,
        "capability_route.candidate_recorded",
        &resource,
        json!({
            "targetOperation": TARGET_OPERATION,
            "candidateState": state,
            "runtimeRoutingChanged": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION,
        "operation": "capability_replacement_candidate_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityReplacementCandidateResourceId": resource.resource_id,
        "capabilityReplacementCandidateVersionId": version_id,
        "replacementCandidate": route_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_replacement_candidate")]
    }))
}

pub(crate) async fn list_replacement_candidate_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_route_values(
        deps,
        invocation,
        payload,
        "capability_replacement_candidate_list",
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        "validated",
        "replacementCandidates",
    )
    .await
}

pub(crate) async fn inspect_replacement_candidate_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_route_value(
        deps,
        invocation,
        payload,
        "capability_replacement_candidate_inspect",
        "capabilityReplacementCandidateResourceId",
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        ensure_capability_replacement_candidate,
        CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION,
        "replacementCandidate",
    )
    .await
}

pub(crate) async fn record_route_binding_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant =
        ensure_route_write_authority(deps, invocation, "capability_route_binding_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let binding_id = bounded_provider_visible_token(
        "capabilityRouteBindingId",
        &optional_string(payload, "capabilityRouteBindingId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
        REQUEST_ID_MAX_BYTES,
    )?;
    let candidate_resource_id =
        required_string(payload, "capabilityReplacementCandidateResourceId")?;
    validate_route_resource_id(
        &candidate_resource_id,
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
    )?;
    require_exact_resource_selector(
        &grant,
        &candidate_resource_id,
        "capability_route_binding_record",
    )?;
    let candidate_inspection = inspect_resource_required(
        deps,
        &candidate_resource_id,
        "capability replacement candidate",
    )
    .await?;
    ensure_capability_replacement_candidate(
        &candidate_inspection,
        "capability_route_binding_record",
    )?;
    ensure_scope(
        &candidate_inspection,
        &scope,
        "capability_route_binding_record",
    )?;
    if candidate_inspection.resource.lifecycle != "validated" {
        return Err(invalid(
            "capability route binding requires a validated candidate",
        ));
    }
    let (candidate_version, candidate_payload) =
        current_payload(&candidate_inspection, "capability_route_binding_record")?;
    let expected_candidate_version =
        required_string(payload, "expectedCapabilityReplacementCandidateVersionId")?;
    if expected_candidate_version != candidate_version.version_id {
        return Err(invalid(format!(
            "stale capability replacement candidate version {expected_candidate_version}"
        )));
    }
    let shadow_evidence = validated_shadow_evidence_from_candidate(
        deps,
        Some(&grant),
        &scope,
        candidate_payload,
        "capability_route_binding_record",
    )
    .await?;
    let route_version = bounded_provider_visible_token(
        "routeVersion",
        &required_string(payload, "routeVersion")?,
        TOKEN_MAX_BYTES,
    )?;
    let state = route_state(payload, "lifecycleState", &["ready", "disabled"])?;
    let audit_refs = safe_refs(payload, "auditRefs")?;
    let now = operation_at.to_rfc3339();
    let resource_id = route_resource_id(
        CAPABILITY_ROUTE_BINDING_KIND,
        &scope,
        &binding_id,
        &idempotency_key,
    );
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_route_binding(&existing, "capability_route_binding_record replay")?;
        ensure_scope(&existing, &scope, "capability_route_binding_record replay")?;
        let (version, payload) =
            current_payload(&existing, "capability_route_binding_record replay")?;
        return Ok(json!({
            "schemaVersion": CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION,
            "operation": "capability_route_binding_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "capabilityRouteBindingResourceId": resource_id,
            "capabilityRouteBindingVersionId": version.version_id,
            "routeBinding": route_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "capability_route_binding")]
        }));
    }
    let record = json!({
        "schemaVersion": CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION,
        "state": state,
        "routeBindingId": binding_id,
        "scope": scope_ref(&scope),
        "operation": candidate_payload["operation"],
        "candidate": candidate_payload["candidate"],
        "binding": {
            "routeVersion": route_version,
            "candidate": version_ref(&candidate_inspection.resource, candidate_version, "replacement_candidate"),
            "shadowEvidence": shadow_evidence,
            "targetOperation": TARGET_OPERATION,
            "scopeKind": scope.kind(),
            "scopeValueRedacted": true,
            "routeCanActivate": state == "ready",
            "dispatchMutationRequired": false,
            "networkPolicy": "none"
        },
        "activationGate": {
            "requiresApproval": true,
            "requiresShadowEvidence": true,
            "requiresRollback": true,
            "requiresDisable": true,
            "requiresExactScope": true,
            "requiresCurrentCandidateVersion": true
        },
        "auditRefs": audit_refs,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "idempotency": idempotency_evidence(&idempotency_key, ROUTE_BINDING_IDEMPOTENCY_FINGERPRINT_ALGORITHM, ROUTE_BINDING_IDEMPOTENCY_DOMAIN),
        "sideEffectProof": route_side_effect(false),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = create_route_resource(
        deps,
        invocation,
        resource_id.clone(),
        CAPABILITY_ROUTE_BINDING_KIND,
        CAPABILITY_ROUTE_BINDING_SCHEMA_ID,
        &scope,
        &state,
        "capability-route-binding",
        &binding_id,
        record,
    )
    .await?;
    let version_id = current_version_id(&resource, "capability_route_binding_record")?;
    publish_lifecycle_event(
        deps,
        invocation,
        "capability_route.binding_recorded",
        &resource,
        json!({
            "targetOperation": TARGET_OPERATION,
            "routeBindingState": state,
            "runtimeRoutingChanged": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION,
        "operation": "capability_route_binding_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "capabilityRouteBindingResourceId": resource.resource_id,
        "capabilityRouteBindingVersionId": version_id,
        "routeBinding": route_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "capability_route_binding")]
    }))
}

pub(crate) async fn list_route_binding_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_route_values(
        deps,
        invocation,
        payload,
        "capability_route_binding_list",
        CAPABILITY_ROUTE_BINDING_KIND,
        "ready",
        "routeBindings",
    )
    .await
}

pub(crate) async fn inspect_route_binding_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_route_value(
        deps,
        invocation,
        payload,
        "capability_route_binding_inspect",
        "capabilityRouteBindingResourceId",
        CAPABILITY_ROUTE_BINDING_KIND,
        ensure_capability_route_binding,
        CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION,
        "routeBinding",
    )
    .await
}

pub(crate) async fn activate_route_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let activation = route_control_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        RouteControl::Activate,
    )
    .await?;
    Ok(activation)
}

pub(crate) async fn disable_route_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    route_control_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        RouteControl::Disable,
    )
    .await
}

pub(crate) async fn rollback_route_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    route_control_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        RouteControl::Rollback,
    )
    .await
}

pub(crate) async fn list_route_event_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_route_values(
        deps,
        invocation,
        payload,
        "capability_route_event_list",
        CAPABILITY_ROUTE_EVENT_KIND,
        "activated",
        "routeEvents",
    )
    .await
}

pub(crate) async fn inspect_route_event_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_route_value(
        deps,
        invocation,
        payload,
        "capability_route_event_inspect",
        "capabilityRouteEventResourceId",
        CAPABILITY_ROUTE_EVENT_KIND,
        ensure_capability_route_event,
        CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION,
        "routeEvent",
    )
    .await
}

pub(crate) async fn active_route_for_git_status(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Option<ActiveRoute>, CapabilityError> {
    let scope = match resource_scope(invocation) {
        Ok(scope) => scope,
        Err(_) => return Ok(None),
    };
    let activations = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(CAPABILITY_ROUTE_ACTIVATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("active".to_owned()),
            limit: LIST_LIMIT_MAX,
        })
        .await
        .map_err(engine_error)?;
    let mut selected: Option<(String, ActiveRoute)> = None;
    for resource in activations {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_capability_route_activation(&inspection, "capability_route_lookup")?;
        ensure_scope(&inspection, &scope, "capability_route_lookup")?;
        let (version, payload) = current_payload(&inspection, "capability_route_lookup")?;
        if operation_name(payload) != Some(TARGET_OPERATION) {
            continue;
        }
        if route_has_terminal_event(deps, &scope, &inspection.resource.resource_id).await? {
            continue;
        }
        let binding_ref = payload
            .pointer("/binding/resourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("active route is missing route binding ref"))?;
        let expected_binding_version = payload
            .pointer("/binding/versionId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("active route is missing route binding version ref"))?;
        ensure_referenced_route_records(deps, &scope, binding_ref, Some(expected_binding_version))
            .await?;
        let route = ActiveRoute {
            activation_resource_id: inspection.resource.resource_id.clone(),
            activation_version_id: version.version_id.clone(),
            route_version: payload
                .pointer("/activation/routeVersion")
                .and_then(Value::as_str)
                .unwrap_or("route-v1")
                .to_owned(),
            candidate_owner: payload
                .pointer("/candidate/owner")
                .and_then(Value::as_str)
                .unwrap_or("module_candidate")
                .to_owned(),
            candidate_label: payload
                .pointer("/candidate/label")
                .and_then(Value::as_str)
                .unwrap_or("Governed Git status adapter")
                .to_owned(),
        };
        let updated_at = payload
            .get("updatedAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if selected
            .as_ref()
            .is_none_or(|(current, _)| updated_at > *current)
        {
            selected = Some((updated_at, route));
        }
    }
    Ok(selected.map(|(_, route)| route))
}

pub(crate) async fn emit_routed_invocation_event(
    deps: &Deps,
    invocation: &Invocation,
    route: &ActiveRoute,
) -> Result<Option<Value>, CapabilityError> {
    let scope = match resource_scope(invocation) {
        Ok(scope) => scope,
        Err(_) => return Ok(None),
    };
    let now = Utc::now().to_rfc3339();
    let idempotency_key = invocation.id.as_str();
    let event_id = bounded_provider_visible_token(
        "capabilityRouteEventId",
        &format!("{}-routed", invocation.id.as_str()),
        DECISION_ID_MAX_BYTES,
    )?;
    let resource_id = route_resource_id(
        CAPABILITY_ROUTE_EVENT_KIND,
        &scope,
        &event_id,
        idempotency_key,
    );
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_route_event(&existing, "capability_route_event replay")?;
        let (version, payload) = current_payload(&existing, "capability_route_event replay")?;
        return Ok(Some(route_summary(&existing.resource, version, payload)));
    }
    let record = json!({
        "schemaVersion": CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION,
        "state": "routed",
        "routeEventId": event_id,
        "scope": scope_ref(&scope),
        "operation": route_operation_record("active_route"),
        "candidate": {
            "owner": route.candidate_owner,
            "label": route.candidate_label,
            "moduleAdapterInvoked": false,
            "moduleAdapterInvocationState": "deferred_supervised_runtime_adapter",
            "providerSafeProjectionRequired": true
        },
        "binding": {
            "routeVersion": route.route_version,
            "resourceId": route.activation_resource_id,
            "activationVersionId": route.activation_version_id
        },
        "activation": {
            "resourceId": route.activation_resource_id,
            "versionId": route.activation_version_id,
            "active": true
        },
        "event": {
            "kind": "routed_invocation",
            "result": "routed",
            "failClosed": false,
            "traceLinked": true,
            "networkPolicy": "none"
        },
        "auditRefs": [],
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "idempotency": idempotency_evidence(idempotency_key, ROUTE_EVENT_IDEMPOTENCY_FINGERPRINT_ALGORITHM, ROUTE_EVENT_IDEMPOTENCY_DOMAIN),
        "sideEffectProof": route_side_effect(false),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = create_route_resource(
        deps,
        invocation,
        resource_id,
        CAPABILITY_ROUTE_EVENT_KIND,
        CAPABILITY_ROUTE_EVENT_SCHEMA_ID,
        &scope,
        "routed",
        "capability-route-event",
        &event_id,
        record,
    )
    .await?;
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "capability route event").await?;
    let (version, payload) = current_payload(&inspection, "capability route event")?;
    Ok(Some(route_summary(&inspection.resource, version, payload)))
}

pub(crate) async fn annotate_routed_git_status(
    deps: &Deps,
    invocation: &Invocation,
    mut result: CapabilityResult,
    route: &ActiveRoute,
) -> Result<CapabilityResult, CapabilityError> {
    let route_event = emit_routed_invocation_event(deps, invocation, route).await?;
    let details = result.details.get_or_insert_with(|| json!({}));
    if let Some(object) = details.as_object_mut() {
        object.insert(
            "dynamicReplacement".to_owned(),
            json!({
                "operation": TARGET_OPERATION,
                "routeState": "active_route_builtin_projection",
                "routeVersion": route.route_version,
                "candidateOwner": route.candidate_owner,
                "candidateLabel": route.candidate_label,
                "activationResourceId": route.activation_resource_id,
                "activationVersionId": route.activation_version_id,
                "moduleAdapterInvoked": false,
                "moduleAdapterInvocationState": "deferred_supervised_runtime_adapter",
                "builtInProjectionUsed": true,
                "networkPolicy": "none",
                "failClosed": false,
                "routeEvent": route_event
            }),
        );
    }
    Ok(result)
}

async fn route_control_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
    control: RouteControl,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_route_write_authority(deps, invocation, control.operation()).await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let binding_resource_id = required_string(payload, "capabilityRouteBindingResourceId")?;
    validate_route_resource_id(&binding_resource_id, CAPABILITY_ROUTE_BINDING_KIND)?;
    require_exact_resource_selector(&grant, &binding_resource_id, control.operation())?;
    let binding_inspection =
        inspect_resource_required(deps, &binding_resource_id, "capability route binding").await?;
    ensure_capability_route_binding(&binding_inspection, control.operation())?;
    ensure_scope(&binding_inspection, &scope, control.operation())?;
    if binding_inspection.resource.lifecycle != "ready" && control == RouteControl::Activate {
        return Err(invalid(
            "capability route activation requires a ready route binding",
        ));
    }
    let (binding_version, binding_payload) =
        current_payload(&binding_inspection, control.operation())?;
    let expected_binding_version =
        required_string(payload, "expectedCapabilityRouteBindingVersionId")?;
    if expected_binding_version != binding_version.version_id {
        return Err(invalid(format!(
            "stale capability route binding version {expected_binding_version}"
        )));
    }
    let activation_id = bounded_provider_visible_token(
        "capabilityRouteActivationId",
        &optional_string(payload, "capabilityRouteActivationId")?
            .unwrap_or_else(|| invocation.id.as_str().to_owned()),
        REQUEST_ID_MAX_BYTES,
    )?;
    ensure_referenced_route_records(
        deps,
        &scope,
        &binding_resource_id,
        Some(&binding_version.version_id),
    )
    .await?;
    let audit_refs = safe_refs(payload, "auditRefs")?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let now = operation_at.to_rfc3339();
    match control {
        RouteControl::Activate => {
            let approval_refs = safe_refs(payload, "approvalRefs")?;
            if approval_refs.is_empty() {
                return Err(invalid("capability route activation requires approvalRefs"));
            }
            let route_version = binding_payload
                .pointer("/binding/routeVersion")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid("route binding is missing routeVersion"))?;
            let resource_id = route_resource_id(
                CAPABILITY_ROUTE_ACTIVATION_KIND,
                &scope,
                &activation_id,
                &idempotency_key,
            );
            if let Some(existing) = deps
                .engine_host
                .inspect_resource(&resource_id)
                .await
                .map_err(engine_error)?
            {
                ensure_capability_route_activation(&existing, "capability_route_activate replay")?;
                let (version, payload) =
                    current_payload(&existing, "capability_route_activate replay")?;
                return Ok(json!({
                    "schemaVersion": CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION,
                    "operation": "capability_route_activate",
                    "status": existing.resource.lifecycle,
                    "idempotentReplay": true,
                    "capabilityRouteActivationResourceId": resource_id,
                    "capabilityRouteActivationVersionId": version.version_id,
                    "routeActivation": route_summary(&existing.resource, version, payload),
                    "resourceRefs": [version_ref(&existing.resource, version, "capability_route_activation")]
                }));
            }
            let record = json!({
                "schemaVersion": CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION,
                "state": "active",
                "routeActivationId": activation_id,
                "scope": scope_ref(&scope),
                "operation": binding_payload["operation"],
                "candidate": binding_payload["candidate"],
                "binding": {
                    "resourceId": binding_inspection.resource.resource_id,
                    "versionId": binding_version.version_id,
                    "routeVersion": route_version
                },
                "activation": {
                    "reason": reason,
                    "routeVersion": route_version,
                    "approved": true,
                    "approvalRefs": approval_refs,
                    "active": true,
                    "rollbackAvailable": true,
                    "disableAvailable": true,
                    "scopeExact": true,
                    "runtimeRoutingEnabled": true,
                    "dispatchTableMutated": false,
                    "networkPolicy": "none"
                },
                "auditRefs": audit_refs,
                "traceRefs": trace_refs(invocation),
                "replayRefs": replay_refs(invocation),
                "idempotency": idempotency_evidence(&idempotency_key, ROUTE_ACTIVATION_IDEMPOTENCY_FINGERPRINT_ALGORITHM, ROUTE_ACTIVATION_IDEMPOTENCY_DOMAIN),
                "sideEffectProof": route_side_effect(true),
                "createdAt": now,
                "updatedAt": now,
                "revision": 1
            });
            let resource = create_route_resource(
                deps,
                invocation,
                resource_id,
                CAPABILITY_ROUTE_ACTIVATION_KIND,
                CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
                &scope,
                "active",
                "capability-route-activation",
                &activation_id,
                record,
            )
            .await?;
            let version_id = current_version_id(&resource, "capability_route_activate")?;
            let event = create_control_event(
                deps,
                invocation,
                &scope,
                "activated",
                &binding_inspection.resource,
                binding_version,
                &resource,
                &activation_id,
                &idempotency_key,
                &now,
                &reason,
            )
            .await?;
            publish_lifecycle_event(
                deps,
                invocation,
                "capability_route.activated",
                &resource,
                json!({
                    "targetOperation": TARGET_OPERATION,
                    "runtimeRoutingChanged": true,
                    "routeVersion": route_version,
                    "networkPolicy": "none"
                }),
            )
            .await?;
            Ok(json!({
                "schemaVersion": CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION,
                "operation": "capability_route_activate",
                "status": resource.lifecycle,
                "idempotentReplay": false,
                "capabilityRouteActivationResourceId": resource.resource_id,
                "capabilityRouteActivationVersionId": version_id,
                "routeActivation": route_summary_for_resource(deps, &resource).await?,
                "routeEvent": event,
                "resourceRefs": [resource_ref(&resource, "capability_route_activation")]
            }))
        }
        RouteControl::Disable | RouteControl::Rollback => {
            let activation_resource_id =
                required_string(payload, "capabilityRouteActivationResourceId")?;
            validate_route_resource_id(&activation_resource_id, CAPABILITY_ROUTE_ACTIVATION_KIND)?;
            require_exact_resource_selector(&grant, &activation_resource_id, control.operation())?;
            let activation_inspection = inspect_resource_required(
                deps,
                &activation_resource_id,
                "capability route activation",
            )
            .await?;
            ensure_capability_route_activation(&activation_inspection, control.operation())?;
            ensure_scope(&activation_inspection, &scope, control.operation())?;
            let (activation_version, _activation_payload) =
                current_payload(&activation_inspection, control.operation())?;
            let expected_activation_version =
                required_string(payload, "expectedCapabilityRouteActivationVersionId")?;
            if expected_activation_version != activation_version.version_id {
                return Err(invalid(format!(
                    "stale capability route activation version {expected_activation_version}"
                )));
            }
            let event = create_control_event(
                deps,
                invocation,
                &scope,
                control.state(),
                &binding_inspection.resource,
                binding_version,
                &activation_inspection.resource,
                &activation_id,
                &idempotency_key,
                &now,
                &reason,
            )
            .await?;
            let rollback = if control == RouteControl::Rollback {
                let rollback_id = bounded_provider_visible_token(
                    "capabilityRouteRollbackId",
                    &optional_string(payload, "capabilityRouteRollbackId")?
                        .unwrap_or_else(|| format!("{activation_id}-rollback")),
                    REQUEST_ID_MAX_BYTES,
                )?;
                let rollback_resource_id = route_resource_id(
                    CAPABILITY_ROUTE_ROLLBACK_KIND,
                    &scope,
                    &rollback_id,
                    &idempotency_key,
                );
                let rollback_record = json!({
                    "schemaVersion": CAPABILITY_ROUTE_ROLLBACK_SCHEMA_VERSION,
                    "state": "rolled_back",
                    "routeRollbackId": rollback_id,
                    "scope": scope_ref(&scope),
                    "operation": binding_payload["operation"],
                    "candidate": binding_payload["candidate"],
                    "binding": version_ref(&binding_inspection.resource, binding_version, "route_binding"),
                    "activation": version_ref(&activation_inspection.resource, activation_version, "route_activation"),
                    "rollback": {
                        "reason": reason,
                        "builtInRestored": true,
                        "rollbackDeterministic": true,
                        "networkPolicy": "none"
                    },
                    "auditRefs": audit_refs,
                    "traceRefs": trace_refs(invocation),
                    "replayRefs": replay_refs(invocation),
                    "idempotency": idempotency_evidence(&idempotency_key, ROUTE_ROLLBACK_IDEMPOTENCY_FINGERPRINT_ALGORITHM, ROUTE_ROLLBACK_IDEMPOTENCY_DOMAIN),
                    "sideEffectProof": route_side_effect(true),
                    "createdAt": now,
                    "updatedAt": now,
                    "revision": 1
                });
                let rollback_resource = create_route_resource(
                    deps,
                    invocation,
                    rollback_resource_id,
                    CAPABILITY_ROUTE_ROLLBACK_KIND,
                    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID,
                    &scope,
                    "rolled_back",
                    "capability-route-rollback",
                    &rollback_id,
                    rollback_record,
                )
                .await?;
                Some(route_summary_for_resource(deps, &rollback_resource).await?)
            } else {
                None
            };
            publish_lifecycle_event(
                deps,
                invocation,
                if control == RouteControl::Rollback {
                    "capability_route.rolled_back"
                } else {
                    "capability_route.disabled"
                },
                &activation_inspection.resource,
                json!({
                    "targetOperation": TARGET_OPERATION,
                    "runtimeRoutingChanged": true,
                    "routeControl": control.state(),
                    "networkPolicy": "none"
                }),
            )
            .await?;
            Ok(json!({
                "schemaVersion": if control == RouteControl::Rollback {
                    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_VERSION
                } else {
                    CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION
                },
                "operation": control.operation(),
                "status": control.state(),
                "routeEvent": event,
                "routeRollback": rollback,
                "resourceRefs": []
            }))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RouteControl {
    Activate,
    Disable,
    Rollback,
}

impl RouteControl {
    fn operation(self) -> &'static str {
        match self {
            Self::Activate => "capability_route_activate",
            Self::Disable => "capability_route_disable",
            Self::Rollback => "capability_route_rollback",
        }
    }

    fn state(self) -> &'static str {
        match self {
            Self::Activate => "activated",
            Self::Disable => "disabled",
            Self::Rollback => "rolled_back",
        }
    }
}

async fn list_route_values(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    kind: &str,
    default_lifecycle: &str,
    output_key: &str,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_route_read_grant(deps, invocation, operation).await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = payload
        .get("includeArchived")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let lifecycle = optional_string(payload, "lifecycle")?;
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
        if let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            ensure_route_kind(&inspection, operation, kind)?;
            ensure_scope(&inspection, &scope, operation)?;
            let (version, payload) = current_payload(&inspection, operation)?;
            items.push(route_summary(&inspection.resource, version, payload));
        }
    }
    Ok(json!({
        "schemaVersion": route_schema_for_kind(kind),
        "operation": operation,
        "scope": scope_ref(&scope),
        output_key: items,
        "limits": {
            "requestedLimit": limit,
            "returned": items.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": route_side_effect(false)
    }))
}

async fn inspect_route_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    id_field: &str,
    kind: &str,
    ensure: fn(&EngineResourceInspection, &str) -> Result<(), CapabilityError>,
    schema_version: &'static str,
    output_key: &str,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_route_read_grant(deps, invocation, operation).await?;
    let resource_id = required_string(payload, id_field)?;
    validate_route_resource_id(&resource_id, kind)?;
    require_exact_resource_selector(&grant, &resource_id, operation)?;
    let scope = resource_scope(invocation)?;
    let inspection = inspect_resource_required(deps, &resource_id, output_key).await?;
    ensure(&inspection, operation)?;
    ensure_scope(&inspection, &scope, operation)?;
    let (version, payload) = current_payload(&inspection, operation)?;
    Ok(json!({
        "schemaVersion": schema_version,
        "operation": operation,
        "scope": scope_ref(&scope),
        output_key: route_inspection(&inspection.resource, version, payload),
        "history": {
            "resourceEvents": inspection.events.len(),
            "versions": inspection.versions.len(),
            "currentVersionId": inspection.resource.current_version_id.as_deref(),
            "auditBackedByResourceEvents": true
        },
        "sideEffects": route_side_effect(false)
    }))
}

async fn create_control_event(
    deps: &Deps,
    invocation: &Invocation,
    scope: &EngineResourceScope,
    state: &str,
    binding_resource: &EngineResource,
    binding_version: &EngineResourceVersion,
    activation_resource: &EngineResource,
    visible_id: &str,
    idempotency_key: &str,
    now: &str,
    reason: &str,
) -> Result<Value, CapabilityError> {
    let event_id = bounded_provider_visible_token(
        "capabilityRouteEventId",
        &format!("{visible_id}-{state}"),
        DECISION_ID_MAX_BYTES,
    )?;
    let resource_id = route_resource_id(
        CAPABILITY_ROUTE_EVENT_KIND,
        scope,
        &event_id,
        idempotency_key,
    );
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_capability_route_event(&existing, "capability_route_event replay")?;
        let (version, payload) = current_payload(&existing, "capability_route_event replay")?;
        return Ok(route_summary(&existing.resource, version, payload));
    }
    let record = json!({
        "schemaVersion": CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION,
        "state": state,
        "routeEventId": event_id,
        "scope": scope_ref(scope),
        "operation": route_operation_record(state),
        "candidate": {
            "owner": "module_candidate",
            "label": "Governed Git status adapter",
            "providerSafeProjectionRequired": true
        },
        "binding": version_ref(binding_resource, binding_version, "route_binding"),
        "activation": resource_ref(activation_resource, "route_activation"),
        "event": {
            "kind": state,
            "reason": reason,
            "failClosed": false,
            "networkPolicy": "none"
        },
        "auditRefs": [],
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "idempotency": idempotency_evidence(idempotency_key, ROUTE_EVENT_IDEMPOTENCY_FINGERPRINT_ALGORITHM, ROUTE_EVENT_IDEMPOTENCY_DOMAIN),
        "sideEffectProof": route_side_effect(state != "routed"),
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = create_route_resource(
        deps,
        invocation,
        resource_id,
        CAPABILITY_ROUTE_EVENT_KIND,
        CAPABILITY_ROUTE_EVENT_SCHEMA_ID,
        scope,
        state,
        "capability-route-event",
        &event_id,
        record,
    )
    .await?;
    route_summary_for_resource(deps, &resource).await
}

async fn create_route_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: String,
    kind: &str,
    schema_id: &str,
    scope: &EngineResourceScope,
    lifecycle: &str,
    location_kind: &str,
    visible_id: &str,
    initial_payload: Value,
) -> Result<EngineResource, CapabilityError> {
    deps.engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: kind.to_owned(),
            schema_id: Some(schema_id.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: route_resource_policy(kind),
            initial_payload: Some(initial_payload),
            locations: vec![EngineResourceLocation {
                kind: location_kind.to_owned(),
                uri: format!("{location_kind}:{visible_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

async fn ensure_referenced_route_records(
    deps: &Deps,
    scope: &EngineResourceScope,
    binding_resource_id: &str,
    expected_binding_version: Option<&str>,
) -> Result<(), CapabilityError> {
    let binding =
        inspect_resource_required(deps, binding_resource_id, "capability route binding").await?;
    ensure_capability_route_binding(&binding, "capability_route_lookup")?;
    ensure_scope(&binding, scope, "capability_route_lookup")?;
    let (binding_version, binding_payload) = current_payload(&binding, "capability_route_lookup")?;
    if let Some(expected_binding_version) = expected_binding_version
        && expected_binding_version != binding_version.version_id
    {
        return Err(invalid(format!(
            "stale capability route binding version {expected_binding_version}"
        )));
    }
    let candidate_resource_id = binding_payload
        .pointer("/binding/candidate/resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("active route binding is missing candidate ref"))?;
    let expected_candidate_version = binding_payload
        .pointer("/binding/candidate/versionId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("active route binding is missing candidate version ref"))?;
    let candidate = inspect_resource_required(
        deps,
        candidate_resource_id,
        "capability replacement candidate",
    )
    .await?;
    ensure_capability_replacement_candidate(&candidate, "capability_route_lookup")?;
    ensure_scope(&candidate, scope, "capability_route_lookup")?;
    if candidate.resource.lifecycle != "validated" {
        return Err(invalid("active route candidate is no longer validated"));
    }
    let (candidate_version, candidate_payload) =
        current_payload(&candidate, "capability_route_lookup")?;
    if expected_candidate_version != candidate_version.version_id {
        return Err(invalid(format!(
            "stale capability replacement candidate version {expected_candidate_version}"
        )));
    }
    validated_shadow_evidence_from_candidate(
        deps,
        None,
        scope,
        candidate_payload,
        "capability_route_lookup",
    )
    .await?;
    Ok(())
}

async fn route_has_terminal_event(
    deps: &Deps,
    scope: &EngineResourceScope,
    activation_resource_id: &str,
) -> Result<bool, CapabilityError> {
    let events = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(CAPABILITY_ROUTE_EVENT_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: None,
            limit: LIST_LIMIT_MAX,
        })
        .await
        .map_err(engine_error)?;
    for resource in events {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let (_, payload) = current_payload(&inspection, "capability_route_lookup")?;
        let event_activation = payload
            .pointer("/activation/resourceId")
            .and_then(Value::as_str)
            .or_else(|| {
                payload
                    .pointer("/activation/resource/resourceId")
                    .and_then(Value::as_str)
            });
        if event_activation == Some(activation_resource_id)
            && matches!(resource.lifecycle.as_str(), "disabled" | "rolled_back")
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn route_target_metadata(payload: &Value) -> Result<Value, CapabilityError> {
    let target = target_operation_binding_metadata(payload)?;
    if target.operation_name != TARGET_OPERATION {
        return Err(invalid(
            "runtime replacement routing currently targets exactly git_status",
        ));
    }
    if target.ownership_class != "adapter_replaceable" {
        return Err(invalid(
            "git_status replacement requires adapter_replaceable ownership",
        ));
    }
    Ok(json!({
        "name": target.operation_name,
        "family": target.family,
        "currentBuiltInOwner": target.current_owner,
        "ownershipClass": target.ownership_class,
        "requestedReplacementTarget": target.replacement_target,
        "currentExecutionOwner": "builtin",
        "dispatchChanged": false
    }))
}

fn route_operation_record(reason: &str) -> Value {
    json!({
        "name": TARGET_OPERATION,
        "family": "git",
        "currentBuiltInOwner": "domains::capability::operations::git + domains::git",
        "ownershipClass": "adapter_replaceable",
        "requestedReplacementTarget": "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        "currentExecutionOwner": "builtin_projection_under_governed_route",
        "routeReason": reason,
        "dispatchChanged": false
    })
}

struct ValidatedShadowEvidence {
    version_ref: Value,
}

async fn validated_shadow_evidence_from_payload(
    deps: &Deps,
    grant: Option<&EngineGrant>,
    scope: &EngineResourceScope,
    payload: &Value,
    operation: &str,
) -> Result<ValidatedShadowEvidence, CapabilityError> {
    let shadow_evidence_ref = required_shadow_evidence_ref(payload)?;
    validated_shadow_evidence_ref(deps, grant, scope, &shadow_evidence_ref, operation).await
}

async fn validated_shadow_evidence_from_candidate(
    deps: &Deps,
    grant: Option<&EngineGrant>,
    scope: &EngineResourceScope,
    candidate_payload: &Value,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let Some(shadow_evidence_ref) = candidate_payload.pointer("/candidate/shadowEvidenceRef")
    else {
        return Err(invalid(
            "capability replacement candidate is missing shadow evidence ref",
        ));
    };
    validated_shadow_evidence_ref(deps, grant, scope, shadow_evidence_ref, operation)
        .await
        .map(|evidence| evidence.version_ref)
}

async fn validated_shadow_evidence_ref(
    deps: &Deps,
    grant: Option<&EngineGrant>,
    scope: &EngineResourceScope,
    shadow_evidence_ref: &Value,
    operation: &str,
) -> Result<ValidatedShadowEvidence, CapabilityError> {
    if shadow_evidence_ref.get("kind").and_then(Value::as_str)
        != Some(CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND)
    {
        return Err(invalid(
            "shadowEvidenceRef must reference capability_shadow_trial_evidence",
        ));
    }
    let resource_id = shadow_evidence_ref
        .get("resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("shadowEvidenceRef requires resourceId"))?;
    validate_route_resource_id(resource_id, CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND)?;
    if let Some(grant) = grant {
        require_exact_resource_selector(grant, resource_id, operation)?;
    }
    let inspection =
        inspect_resource_required(deps, resource_id, "capability shadow trial evidence").await?;
    ensure_capability_shadow_trial_evidence(&inspection, operation)?;
    ensure_scope(&inspection, scope, operation)?;
    if inspection.resource.lifecycle != "accepted" {
        return Err(invalid(
            "capability route requires accepted shadow trial evidence",
        ));
    }
    let (version, payload) = current_payload(&inspection, operation)?;
    let expected_version = shadow_evidence_ref
        .get("versionId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("shadowEvidenceRef requires versionId"))?;
    if expected_version != version.version_id {
        return Err(invalid(format!(
            "stale capability shadow trial evidence version {expected_version}"
        )));
    }
    if payload
        .pointer("/comparison/result")
        .and_then(Value::as_str)
        != Some("equivalent")
    {
        return Err(invalid(
            "capability route requires equivalent shadow trial evidence",
        ));
    }
    if payload
        .pointer("/sideEffectProof/runtimeRoutingChanged")
        .and_then(Value::as_bool)
        != Some(false)
    {
        return Err(invalid(
            "capability route shadow evidence must prove runtime routing was unchanged",
        ));
    }
    Ok(ValidatedShadowEvidence {
        version_ref: version_ref(&inspection.resource, version, "shadow_evidence"),
    })
}

fn required_shadow_evidence_ref(payload: &Value) -> Result<Value, CapabilityError> {
    let raw_ref = payload
        .get("shadowEvidenceRef")
        .ok_or_else(|| invalid("shadowEvidenceRef is required"))?;
    let mut shadow_evidence_ref = required_ref(payload, "shadowEvidenceRef")?;
    let version_id = raw_ref
        .get("versionId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("shadowEvidenceRef requires versionId"))?;
    if let Some(object) = shadow_evidence_ref.as_object_mut() {
        object.insert(
            "versionId".to_owned(),
            json!(bounded_provider_visible_token(
                "shadowEvidenceRef.versionId",
                version_id,
                TOKEN_MAX_BYTES,
            )?),
        );
    }
    Ok(shadow_evidence_ref)
}

fn candidate_contract(
    payload: &Value,
    shadow_evidence: ValidatedShadowEvidence,
) -> Result<Value, CapabilityError> {
    let label = bounded_text(
        "candidateLabel",
        &required_string(payload, "candidateLabel")?,
        SUMMARY_MAX_BYTES,
    )?;
    let owner = bounded_provider_visible_token(
        "candidateOwner",
        &required_string(payload, "candidateOwner")?,
        TOKEN_MAX_BYTES,
    )?;
    let module_ref = required_ref(payload, "moduleRef")?;
    let runtime_ref = required_ref(payload, "moduleRuntimeRef")?;
    let lifecycle_ref = required_ref(payload, "moduleLifecycleRef")?;
    Ok(json!({
        "label": label,
        "owner": owner,
        "moduleRef": module_ref,
        "moduleRuntimeRef": runtime_ref,
        "moduleLifecycleRef": lifecycle_ref,
        "shadowEvidenceRef": shadow_evidence.version_ref,
        "operation": TARGET_OPERATION,
        "outputContract": "git_status_provider_safe_projection_v1",
        "executionMode": "supervised_module_runtime_adapter",
        "moduleAdapterInvokedByDispatcher": false,
        "moduleAdapterInvocationState": "deferred_until_supervised_runtime_projection_call",
        "providerSafeProjectionRequired": true
    }))
}

fn contract_evidence(payload: &Value) -> Result<Value, CapabilityError> {
    let refs = safe_refs(payload, "contractEvidenceRefs")?;
    if refs.is_empty() {
        return Err(invalid(
            "capability replacement candidates require contractEvidenceRefs",
        ));
    }
    Ok(json!({
        "contractEvidenceRefs": refs,
        "schemaCompatible": true,
        "shadowTrialPassed": true,
        "providerSafeProjectionRequired": true,
        "staleEvidenceRejected": true
    }))
}

fn route_authority(payload: &Value) -> Result<Value, CapabilityError> {
    let authority = authority_constraints(payload)?;
    let resource_selectors = authority
        .get("resourceSelectors")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("capability route authority requires exact resourceSelectors"))?;
    if resource_selectors.is_empty() {
        return Err(invalid(
            "capability route authority requires exact resourceSelectors",
        ));
    }
    for selector in resource_selectors {
        let selector = selector
            .as_str()
            .ok_or_else(|| invalid("capability route authority requires string selectors"))?;
        if !selector.starts_with("resource:") {
            return Err(invalid(
                "capability route authority requires resource-scoped exact selectors",
            ));
        }
    }
    Ok(json!({
        "networkPolicy": authority["networkPolicy"],
        "authorityScopes": authority["authorityScopes"],
        "resourceKinds": authority["resourceKinds"],
        "resourceSelectors": authority["resourceSelectors"],
        "exactScopeRequired": true,
        "wildcardSelectorsAllowed": false,
        "agentStateInherited": false,
        "rawGrantIdsStored": false,
        "exactSelectorsRequired": true
    }))
}

fn rollback_controls(payload: &Value) -> Result<Value, CapabilityError> {
    Ok(json!({
        "rollbackRef": required_ref(payload, "rollbackRef")?,
        "disableRef": required_ref(payload, "disableRef")?,
        "rollbackRequired": true,
        "disableRequired": true,
        "builtInResumeAvailable": true
    }))
}

fn route_state(payload: &Value, field: &str, allowed: &[&str]) -> Result<String, CapabilityError> {
    let state = optional_string(payload, field)?.unwrap_or_else(|| allowed[0].to_owned());
    if allowed.iter().any(|allowed| *allowed == state) {
        Ok(state)
    } else {
        Err(invalid(format!("unsupported route lifecycle {state}")))
    }
}

fn safe_refs(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    validate_ref_array(
        field,
        &optional_array(payload, field)?.unwrap_or_default(),
        MAX_REFS,
    )
}

fn route_resource_id(
    kind: &str,
    scope: &EngineResourceScope,
    visible_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(kind, scope, visible_id, idempotency_key)
}

fn validate_route_resource_id(value: &str, expected_kind: &str) -> Result<(), CapabilityError> {
    let prefix = format!("{expected_kind}:");
    if !value.starts_with(&prefix) {
        return Err(invalid(format!("resource id must start with {prefix}")));
    }
    bounded_provider_visible_token("routeResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

fn ensure_route_kind(
    inspection: &EngineResourceInspection,
    operation: &str,
    kind: &str,
) -> Result<(), CapabilityError> {
    match kind {
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND => {
            ensure_capability_replacement_candidate(inspection, operation)
        }
        CAPABILITY_ROUTE_BINDING_KIND => ensure_capability_route_binding(inspection, operation),
        CAPABILITY_ROUTE_ACTIVATION_KIND => {
            ensure_capability_route_activation(inspection, operation)
        }
        CAPABILITY_ROUTE_EVENT_KIND => ensure_capability_route_event(inspection, operation),
        CAPABILITY_ROUTE_ROLLBACK_KIND => ensure_capability_route_rollback(inspection, operation),
        _ => Err(invalid("unsupported route resource kind")),
    }
}

fn route_schema_for_kind(kind: &str) -> &'static str {
    match kind {
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND => CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION,
        CAPABILITY_ROUTE_BINDING_KIND => CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION,
        CAPABILITY_ROUTE_ACTIVATION_KIND => CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION,
        CAPABILITY_ROUTE_EVENT_KIND => CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION,
        CAPABILITY_ROUTE_ROLLBACK_KIND => CAPABILITY_ROUTE_ROLLBACK_SCHEMA_VERSION,
        _ => "tron.capability_route.unknown",
    }
}

fn route_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "state": resource.lifecycle,
        "versionId": version.version_id,
        "operation": payload.get("operation"),
        "candidate": payload.get("candidate"),
        "binding": payload.get("binding"),
        "activation": payload.get("activation"),
        "event": payload.get("event"),
        "rollback": payload.get("rollback"),
        "createdAt": payload.get("createdAt"),
        "updatedAt": payload.get("updatedAt"),
        "resourceRefs": [version_ref(resource, version, "capability_route")]
    })
}

fn route_inspection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "routeRecord": route_summary(resource, version, payload),
        "auditRefs": payload.get("auditRefs"),
        "traceRefs": payload.get("traceRefs"),
        "replayRefs": payload.get("replayRefs"),
        "sideEffectProof": payload.get("sideEffectProof"),
        "projection": {
            "providerSafe": true,
            "rawResourceIdsReturned": false,
            "rawPathsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "rawGrantIdsReturned": false,
            "rawAuthorityIdsReturned": false
        }
    })
}

async fn route_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "capability route").await?;
    let (version, payload) = current_payload(&inspection, "capability route projection")?;
    Ok(route_summary(&inspection.resource, version, payload))
}

fn current_version_id(
    resource: &EngineResource,
    operation: &str,
) -> Result<String, CapabilityError> {
    resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))
}

fn operation_name(payload: &Value) -> Option<&str> {
    payload.pointer("/operation/name").and_then(Value::as_str)
}

fn route_resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "metadataOnly": true,
        "runtimeRouting": "governed_explicit_scoped_reversible",
        "dispatchTableMutation": "forbidden",
        "hotSwap": "forbidden",
        "moduleActivation": "forbidden",
        "packageManager": "forbidden",
        "networkPolicy": "none",
        "approvalEvidenceIsAuthority": false
    })
}

fn route_side_effect(runtime_routing_changed: bool) -> Value {
    json!({
        "metadataOnly": true,
        "runtimeRoutingChanged": runtime_routing_changed,
        "dispatchTableMutated": false,
        "hotSwapPerformed": false,
        "moduleActivated": false,
        "moduleExecuted": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "manifestMutated": false,
        "lockfileMutated": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false,
        "rawGrantIdsStored": false,
        "rawAuthorityIdsStored": false
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "resourceId": invocation.causal_context.trace_id.as_str(),
        "role": "capability_route_trace",
        "storedRawPayload": false
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "resourceId": invocation.id.as_str(),
        "role": "capability_route_replay",
        "idempotent": true,
        "storedRawPayload": false
    })]
}
