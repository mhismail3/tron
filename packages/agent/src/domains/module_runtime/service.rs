use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceLocation, Invocation, ListResources, UpdateResource,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::MODULE_RUNTIME_STATE_SCHEMA_VERSION;
use super::projection::{inspected_module_runtime, module_runtime_summary};
use super::records::{
    ModuleRuntimeRecordInput, idempotency_fingerprint, module_runtime_record,
    module_runtime_resource_id, resource_policy, resource_ref, scope_ref, side_effect_proof,
    version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_module_runtime_state, ensure_scope,
    inspect_resource_required, module_runtime_summary_for_resource, publish_lifecycle_event,
    worker_id,
};
use super::validation::*;
use super::{Deps, MODULE_RUNTIME_STATE_KIND, MODULE_RUNTIME_STATE_SCHEMA_ID};

pub(crate) async fn request_module_runtime_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "module_runtime_request").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let lifecycle_resource_id = required_string(payload, "moduleLifecycleResourceId")?;
    validate_module_lifecycle_resource_id(&lifecycle_resource_id)?;
    require_exact_resource_selector(&grant, &lifecycle_resource_id, "module_runtime_request")?;
    let lifecycle_deps = crate::domains::module_lifecycle::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let lifecycle_authorization =
        crate::domains::module_lifecycle::service::ensure_runtime_allowed(
            &lifecycle_deps,
            &scope,
            &lifecycle_resource_id,
        )
        .await?;
    let request_id_input = required_string(payload, "runtimeRequestId")?;
    let runtime_request_id =
        bounded_provider_visible_token("runtimeRequestId", &request_id_input, TOKEN_MAX_BYTES)?;
    let resource_id =
        module_runtime_resource_id(&scope, &lifecycle_resource_id, &runtime_request_id);
    require_exact_resource_selector(&grant, &resource_id, "module_runtime_request")?;
    let state = runtime_state(payload)?;
    let runtime_kind = bounded_provider_visible_token(
        "runtimeKind",
        &required_string(payload, "runtimeKind")?,
        TOKEN_MAX_BYTES,
    )?;
    let runtime_label = bounded_text(
        "runtimeLabel",
        &required_string(payload, "runtimeLabel")?,
        SUMMARY_MAX_BYTES,
    )?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let input_refs = validate_ref_array(
        "inputRefs",
        &optional_array(payload, "inputRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let output_refs = validate_ref_array(
        "outputArtifactRefs",
        &optional_array(payload, "outputArtifactRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let evidence_refs = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let timeout_ms = timeout_ms(payload)?;
    let timeout_at = operation_at
        .checked_add_signed(Duration::milliseconds(timeout_ms as i64))
        .unwrap_or(operation_at)
        .to_rfc3339();
    let now = operation_at.to_rfc3339();

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_runtime_state(&existing, "module_runtime_request existing state")?;
        ensure_scope(&existing, &scope, "module_runtime_request existing state")?;
        let (current_version, current) =
            current_payload(&existing, "module_runtime_request existing state")?;
        let current_idempotency_fingerprint = current
            .pointer("/idempotency/fingerprint")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("module runtime state is missing idempotency fingerprint"))?;
        if current_idempotency_fingerprint == idempotency_fingerprint(&idempotency_key) {
            return Ok(json!({
                "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
                "operation": "module_runtime_request",
                "status": existing.resource.lifecycle,
                "idempotentReplay": true,
                "moduleRuntimeResourceId": resource_id,
                "moduleRuntimeVersionId": current_version.version_id,
                "moduleRuntime": module_runtime_summary(&existing.resource, current_version, current),
                "resourceRefs": [version_ref(&existing.resource, current_version, "module_runtime_state")]
            }));
        }
        return Err(invalid(
            "module runtime request already exists with a different idempotency fingerprint",
        ));
    }

    let record = module_runtime_record(ModuleRuntimeRecordInput {
        runtime_request_id: &runtime_request_id,
        state: &state,
        reason: &reason,
        runtime_kind: &runtime_kind,
        runtime_label: &runtime_label,
        scope: &scope,
        lifecycle_authorization,
        input_refs,
        output_refs,
        evidence_refs,
        timeout_ms,
        timeout_at: &timeout_at,
        cancellation: json!({"state": "not_requested", "cancelRequested": false}),
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
            kind: MODULE_RUNTIME_STATE_KIND.to_owned(),
            schema_id: Some(MODULE_RUNTIME_STATE_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_runtime_state".to_owned(),
                uri: format!("module-runtime-state:{resource_id}"),
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
        .ok_or_else(|| invalid("module runtime resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_runtime.requested",
        &resource,
        json!({
            "moduleLifecycleResourceId": lifecycle_resource_id,
            "runtimeState": state,
            "timeoutMs": timeout_ms,
            "outputArtifactRefCount": output_refs_len(payload),
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
        "operation": "module_runtime_request",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleRuntimeResourceId": resource.resource_id,
        "moduleRuntimeVersionId": version_id,
        "moduleRuntime": module_runtime_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_runtime_state")]
    }))
}

pub(crate) async fn list_module_runtime_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, "module_runtime_list").await?;
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
            kind: Some(MODULE_RUNTIME_STATE_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some("running".to_owned())
                }
            }),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut runtimes = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_module_runtime_state(&inspection, "module_runtime_list")?;
        ensure_scope(&inspection, &scope, "module_runtime_list")?;
        let (version, payload) = current_payload(&inspection, "module_runtime_list")?;
        runtimes.push(module_runtime_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
        "operation": "module_runtime_list",
        "scope": scope_ref(&scope),
        "moduleRuntimes": runtimes,
        "limits": {
            "requestedLimit": limit,
            "returned": runtimes.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn inspect_module_runtime_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_runtime_inspect").await?;
    let resource_id = required_string(payload, "moduleRuntimeResourceId")?;
    validate_module_runtime_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_runtime_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection = inspect_resource_required(deps, &resource_id, "module runtime state").await?;
    ensure_module_runtime_state(&inspection, "module_runtime_inspect")?;
    ensure_scope(&inspection, &scope, "module_runtime_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_runtime_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
        "operation": "module_runtime_inspect",
        "scope": scope_ref(&scope),
        "moduleRuntime": inspected_module_runtime(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn cancel_module_runtime_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "module_runtime_cancel").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let resource_id = required_string(payload, "moduleRuntimeResourceId")?;
    validate_module_runtime_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_runtime_cancel")?;
    let expected_version_id = required_string(payload, "expectedModuleRuntimeVersionId")?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        SUMMARY_MAX_BYTES,
    )?;
    let inspection = inspect_resource_required(deps, &resource_id, "module runtime state").await?;
    ensure_module_runtime_state(&inspection, "module_runtime_cancel")?;
    ensure_scope(&inspection, &scope, "module_runtime_cancel")?;
    let (current_version, current) = current_payload(&inspection, "module_runtime_cancel")?;
    if current_version.version_id != expected_version_id {
        return Err(invalid(format!(
            "module runtime current version conflict: expected {expected_version_id}, actual {}",
            current_version.version_id
        )));
    }
    if inspection.resource.lifecycle == "cancelled" {
        return Ok(json!({
            "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
            "operation": "module_runtime_cancel",
            "status": inspection.resource.lifecycle,
            "idempotentReplay": true,
            "moduleRuntimeResourceId": resource_id,
            "moduleRuntimeVersionId": current_version.version_id,
            "moduleRuntime": module_runtime_summary(&inspection.resource, current_version, current),
            "resourceRefs": [version_ref(&inspection.resource, current_version, "module_runtime_state")]
        }));
    }
    if matches!(
        inspection.resource.lifecycle.as_str(),
        "completed" | "failed" | "timed_out"
    ) {
        return Err(invalid(format!(
            "module runtime cannot cancel terminal state {}",
            inspection.resource.lifecycle
        )));
    }
    let now = operation_at.to_rfc3339();
    let updated = module_runtime_record(ModuleRuntimeRecordInput {
        runtime_request_id: current
            .get("runtimeRequestId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("module runtime state is missing runtimeRequestId"))?,
        state: "cancelled",
        reason: &reason,
        runtime_kind: current
            .pointer("/runtime/kind")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        runtime_label: current
            .pointer("/runtime/label")
            .and_then(Value::as_str)
            .unwrap_or("runtime cancelled"),
        scope: &scope,
        lifecycle_authorization: current
            .get("moduleLifecycle")
            .cloned()
            .unwrap_or(Value::Null),
        input_refs: current
            .get("inputRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        output_refs: current
            .get("outputArtifactRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        evidence_refs: current
            .get("evidenceRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        timeout_ms: current
            .pointer("/supervision/timeout/timeoutMs")
            .and_then(Value::as_u64)
            .unwrap_or(TIMEOUT_MS_DEFAULT),
        timeout_at: current
            .pointer("/supervision/timeout/deadlineAt")
            .and_then(Value::as_str)
            .unwrap_or(now.as_str()),
        cancellation: json!({
            "state": "cancelled",
            "cancelRequested": true,
            "cancelledAt": now,
            "reason": reason,
            "processSignalSent": false,
            "jobCancelDelegated": false
        }),
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
            lifecycle: Some("cancelled".to_owned()),
            payload: updated,
            state: None,
            locations: vec![EngineResourceLocation {
                kind: "module_runtime_state".to_owned(),
                uri: format!("module-runtime-state:{resource_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let updated = inspect_resource_required(deps, &resource_id, "module runtime state").await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_runtime.cancelled",
        &updated.resource,
        json!({
            "runtimeState": "cancelled",
            "processSignalSent": false,
            "jobCancelDelegated": false,
            "networkPolicy": "none"
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
        "operation": "module_runtime_cancel",
        "status": updated.resource.lifecycle,
        "idempotentReplay": false,
        "moduleRuntimeResourceId": resource_id,
        "moduleRuntimeVersionId": version.version_id,
        "moduleRuntime": module_runtime_summary_for_resource(deps, &updated.resource).await?,
        "resourceRefs": [version_ref(&updated.resource, &version, "module_runtime_state")]
    }))
}

fn output_refs_len(payload: &Value) -> usize {
    payload
        .get("outputArtifactRefs")
        .and_then(Value::as_array)
        .map_or(0, Vec::len)
}
