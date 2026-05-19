//! Generated UI primitive contracts and host-dispatched handlers.
//!
//! `ui_surface` is a resource kind. The `ui::*` capabilities are narrow
//! wrappers around the generic resource store plus the fixed component catalog.
//! They do not own durable state.

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    PrimitiveFunctionRegistration, UI_WORKER_ID, host_dispatched_registration, optional_string,
    primitive_function, required_str, required_string_owned,
};
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::ids::FunctionId;
use crate::engine::primitives::runtime::{PrimitiveRuntimeHost, invocation_record_value};
use crate::engine::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion,
    EngineResourceVersionState, UI_CATALOG_REVISION, UI_SURFACE_KIND, UpdateResource,
    ui_component_catalog, validate_ui_surface_payload,
};
use crate::engine::types::{
    DurableOutputContract, EffectClass, FunctionDefinition, IdempotencyContract, RiskLevel,
    VisibilityScope,
};
use crate::engine::{EngineError, EngineResourceScope, Result, WorkerId, schema};

pub(crate) const CATALOG_FUNCTION: &str = "ui::catalog";
pub(crate) const CREATE_SURFACE_FUNCTION: &str = "ui::create_surface";
pub(crate) const UPDATE_SURFACE_FUNCTION: &str = "ui::update_surface";
pub(crate) const INSPECT_SURFACE_FUNCTION: &str = "ui::inspect_surface";
pub(crate) const DISCARD_SURFACE_FUNCTION: &str = "ui::discard_surface";
pub(crate) const SUBMIT_ACTION_FUNCTION: &str = "ui::submit_action";
pub(crate) const SURFACE_FOR_TARGET_FUNCTION: &str = "ui::surface_for_target";
pub(crate) const VALIDATE_SURFACE_FUNCTION: &str = "ui::validate_surface";
pub(crate) const REFRESH_SURFACE_FUNCTION: &str = "ui::refresh_surface";
pub(crate) const EXPIRE_SURFACE_FUNCTION: &str = "ui::expire_surface";

const GENERATED_AUTHORING_MODE: &str = "generated";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        ui_read(
            CATALOG_FUNCTION,
            "return the fixed generated UI component catalog",
            json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {}
            }),
            json!({
                "type": "object",
                "required": ["catalog"],
                "additionalProperties": false,
                "properties": {"catalog": {"type": "object"}}
            }),
        ),
        ui_write(
            CREATE_SURFACE_FUNCTION,
            "validate and create a generated ui_surface resource",
            create_surface_schema(),
            surface_resource_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            SURFACE_FOR_TARGET_FUNCTION,
            "author or refresh a deterministic generated ui_surface for a substrate target",
            surface_for_target_schema(),
            surface_resource_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            UPDATE_SURFACE_FUNCTION,
            "compare-and-set update a generated ui_surface resource",
            update_surface_schema(),
            surface_version_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_read(
            INSPECT_SURFACE_FUNCTION,
            "inspect a generated ui_surface resource",
            json!({
                "type": "object",
                "required": ["surfaceResourceId"],
                "additionalProperties": false,
                "properties": {"surfaceResourceId": {"type": "string"}}
            }),
            json!({
                "type": "object",
                "required": ["inspection", "validationState", "bindings", "actions", "lineage"],
                "additionalProperties": false,
                "properties": {
                    "inspection": {"type": ["object", "null"]},
                    "surface": {"type": ["object", "null"]},
                    "resourceRef": {"type": ["object", "null"]},
                    "validationState": {"type": "string"},
                    "bindings": {"type": "array"},
                    "actions": {"type": "array"},
                    "lineage": {"type": "object"}
                }
            }),
        ),
        ui_read(
            VALIDATE_SURFACE_FUNCTION,
            "validate a stored ui_surface against current substrate truth",
            json!({
                "type": "object",
                "required": ["surfaceResourceId"],
                "additionalProperties": false,
                "properties": {"surfaceResourceId": {"type": "string"}}
            }),
            json!({
                "type": "object",
                "required": ["surfaceResourceId", "validationState", "diagnostics"],
                "additionalProperties": false,
                "properties": {
                    "surfaceResourceId": {"type": "string"},
                    "validationState": {"type": "string"},
                    "diagnostics": {"type": "array"}
                }
            }),
        ),
        ui_write(
            REFRESH_SURFACE_FUNCTION,
            "refresh a generated ui_surface from stored authoring metadata",
            refresh_surface_schema(),
            surface_version_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            EXPIRE_SURFACE_FUNCTION,
            "expire a ui_surface lifecycle without deleting its payload",
            expire_surface_schema(),
            surface_version_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            DISCARD_SURFACE_FUNCTION,
            "discard a generated ui_surface resource",
            discard_surface_schema(),
            surface_version_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            SUBMIT_ACTION_FUNCTION,
            "submit a stored generated UI action through canonical capability invocation",
            submit_action_schema(),
            json!({
                "type": "object",
                "required": ["surfaceResourceId", "surfaceVersionId", "actionId", "targetFunctionId", "result"],
                "additionalProperties": false,
                "properties": {
                    "surfaceResourceId": {"type": "string"},
                    "surfaceVersionId": {"type": "string"},
                    "actionId": {"type": "string"},
                    "targetFunctionId": {"type": "string"},
                    "childInvocationId": {"type": "string"},
                    "result": {"type": "object"}
                }
            }),
        ),
    ]
    .into_iter()
    .map(host_dispatched_registration)
    .collect())
}

fn ui_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> FunctionDefinition {
    let mut definition = primitive_function(
        id,
        UI_WORKER_ID,
        description,
        EffectClass::PureRead,
        "ui.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    definition
}

fn ui_write(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> FunctionDefinition {
    let mut definition = primitive_function(
        id,
        UI_WORKER_ID,
        description,
        EffectClass::IdempotentWrite,
        "ui.write",
    )
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    definition
}

pub(in crate::engine) fn dispatch(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    match invocation.function_id.as_str() {
        CATALOG_FUNCTION => catalog(),
        CREATE_SURFACE_FUNCTION => create_surface(host, invocation),
        SURFACE_FOR_TARGET_FUNCTION => surface_for_target(host, invocation),
        UPDATE_SURFACE_FUNCTION => update_surface(host, invocation),
        INSPECT_SURFACE_FUNCTION => inspect_surface(host, invocation),
        VALIDATE_SURFACE_FUNCTION => validate_surface(host, invocation),
        REFRESH_SURFACE_FUNCTION => refresh_surface(host, invocation),
        EXPIRE_SURFACE_FUNCTION => expire_surface(host, invocation),
        DISCARD_SURFACE_FUNCTION => discard_surface(host, invocation),
        SUBMIT_ACTION_FUNCTION => Err(EngineError::PolicyViolation(
            "ui::submit_action must execute through the async host action gateway".to_owned(),
        )),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

pub(in crate::engine) fn catalog() -> Result<Value> {
    Ok(json!({ "catalog": ui_component_catalog() }))
}

fn create_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface = normalized_surface_payload(invocation)?;
    validate_surface_targets(host, invocation, &surface)?;
    let resource = host.create_resource(CreateResource {
        resource_id: optional_string(invocation.payload.get("resourceId"))?,
        kind: UI_SURFACE_KIND.to_owned(),
        schema_id: None,
        scope: resource_scope_from_payload(invocation)?,
        owner_worker_id: WorkerId::new(UI_WORKER_ID).unwrap(),
        owner_actor_id: invocation.causal_context.actor_id.clone(),
        lifecycle: Some(surface_lifecycle(invocation, "active")?),
        policy: invocation
            .payload
            .get("policy")
            .cloned()
            .unwrap_or_else(|| json!({})),
        initial_payload: Some(surface),
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(json!({
        "resource": resource,
        "resourceRefs": [resource_ref_from_resource(&resource, "created")],
    }))
}

fn surface_for_target(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let request = SurfaceAuthoringRequest::from_invocation(invocation)?;
    let AuthoredSurface { surface, .. } =
        author_surface_for_target(host, invocation, &request, None)?;
    let resource_id = request
        .existing_surface_resource_id
        .clone()
        .or_else(|| request.resource_id.clone())
        .unwrap_or_else(|| deterministic_surface_resource_id(&request));

    if let Some(existing) = host.inspect_resource(&resource_id)? {
        ensure_ui_surface(&existing)?;
        let expected_current_version_id = request
            .expected_current_version_id
            .clone()
            .or(existing.resource.current_version_id.clone());
        let version = host.update_resource(UpdateResource {
            resource_id,
            expected_current_version_id,
            lifecycle: Some(surface_lifecycle(invocation, "active")?),
            payload: surface.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        Ok(json!({
            "surface": surface,
            "version": version,
            "resourceRefs": [resource_ref_from_version(&version, UI_SURFACE_KIND, "updated")],
        }))
    } else {
        let resource = host.create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: UI_SURFACE_KIND.to_owned(),
            schema_id: None,
            scope: resource_scope_from_payload(invocation)?,
            owner_worker_id: WorkerId::new(UI_WORKER_ID).unwrap(),
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(surface_lifecycle(invocation, "active")?),
            policy: invocation
                .payload
                .get("policy")
                .cloned()
                .unwrap_or_else(|| json!({})),
            initial_payload: Some(surface.clone()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        Ok(json!({
            "surface": surface,
            "resource": resource,
            "resourceRefs": [resource_ref_from_resource(&resource, "created")],
        }))
    }
}

fn update_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface = normalized_surface_payload(invocation)?;
    validate_surface_targets(host, invocation, &surface)?;
    let version = host.update_resource(UpdateResource {
        resource_id: required_string_owned(&invocation.payload, "resourceId")?,
        expected_current_version_id: optional_string(
            invocation.payload.get("expectedCurrentVersionId"),
        )?,
        lifecycle: Some(surface_lifecycle(invocation, "active")?),
        payload: surface,
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref_from_version(&version, UI_SURFACE_KIND, "updated")],
    }))
}

fn inspect_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let inspection = host.inspect_resource(resource_id)?;
    if let Some(inspection) = &inspection {
        ensure_ui_surface(inspection)?;
    }
    let payload = inspection.as_ref().and_then(current_payload);
    let resource_ref = inspection
        .as_ref()
        .and_then(|inspection| {
            inspection
                .resource
                .current_version_id
                .as_ref()
                .map(|_| inspection)
        })
        .map(|inspection| {
            json!({
                "resourceId": inspection.resource.resource_id,
                "kind": inspection.resource.kind,
                "versionId": inspection.resource.current_version_id,
                "role": "current",
                "contentHash": current_version_hash(inspection).unwrap_or_default(),
            })
        });
    let validation_state = surface_validation_state(host, invocation, &inspection).state;
    Ok(json!({
        "inspection": inspection,
        "surface": payload,
        "resourceRef": resource_ref,
        "validationState": validation_state,
        "bindings": payload.as_ref().and_then(|payload| payload.get("bindings")).cloned().unwrap_or_else(|| json!([])),
        "actions": action_summaries(payload.as_ref()),
        "lineage": surface_lineage(inspection.as_ref()),
    }))
}

fn validate_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface_resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let inspection = host.inspect_resource(surface_resource_id)?;
    let validation = surface_validation_state(host, invocation, &inspection);
    Ok(json!({
        "surfaceResourceId": surface_resource_id,
        "validationState": validation.state,
        "diagnostics": validation.diagnostics,
    }))
}

fn refresh_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "surfaceResourceId")?;
    let expected_current_version_id =
        optional_string(invocation.payload.get("expectedCurrentVersionId"))?.ok_or_else(|| {
            EngineError::PolicyViolation(
                "ui::refresh_surface requires expectedCurrentVersionId".to_owned(),
            )
        })?;
    let inspection = host
        .inspect_resource(&resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.clone(),
        })?;
    ensure_ui_surface(&inspection)?;
    let payload = current_payload(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("ui_surface {resource_id} has no current payload"))
    })?;
    let mut request = SurfaceAuthoringRequest::from_authoring_payload(&payload)?;
    request.existing_surface_resource_id = Some(resource_id.clone());
    request.expected_current_version_id = Some(expected_current_version_id.clone());
    request.expected_target_revision = None;
    if DateTime::parse_from_rfc3339(&request.expires_at)
        .map(|expires_at| expires_at.with_timezone(&Utc) <= Utc::now())
        .unwrap_or(true)
    {
        request.expires_at = default_expires_at();
    }
    let AuthoredSurface { mut surface, .. } = author_surface_for_target(
        host,
        invocation,
        &request,
        inspection.resource.current_version_id.as_deref(),
    )?;
    surface["authoring"]["refreshedFromVersionId"] = json!(
        inspection
            .resource
            .current_version_id
            .clone()
            .unwrap_or_default()
    );
    validate_surface_targets(host, invocation, &surface)?;
    validate_ui_surface_payload(&surface)?;
    let version = host.update_resource(UpdateResource {
        resource_id,
        expected_current_version_id: Some(expected_current_version_id),
        lifecycle: Some("active".to_owned()),
        payload: surface.clone(),
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(json!({
        "surface": surface,
        "version": version,
        "resourceRefs": [resource_ref_from_version(&version, UI_SURFACE_KIND, "updated")],
    }))
}

fn expire_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "surfaceResourceId")?;
    let inspection = host
        .inspect_resource(&resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.clone(),
        })?;
    ensure_ui_surface(&inspection)?;
    let payload = current_payload(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("ui_surface {resource_id} has no current payload"))
    })?;
    let expected_current_version_id =
        optional_string(invocation.payload.get("expectedCurrentVersionId"))?
            .or(inspection.resource.current_version_id);
    let version = host.update_resource(UpdateResource {
        resource_id,
        expected_current_version_id,
        lifecycle: Some("expired".to_owned()),
        payload,
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref_from_version(&version, UI_SURFACE_KIND, "expired")],
    }))
}

fn discard_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "surfaceResourceId")?;
    let inspection = host
        .inspect_resource(&resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.clone(),
        })?;
    ensure_ui_surface(&inspection)?;
    let payload = current_payload(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("ui_surface {resource_id} has no current payload"))
    })?;
    let expected_current_version_id =
        optional_string(invocation.payload.get("expectedCurrentVersionId"))?
            .or(inspection.resource.current_version_id);
    let version = host.update_resource(UpdateResource {
        resource_id,
        expected_current_version_id,
        lifecycle: Some("discarded".to_owned()),
        payload,
        state: Some(EngineResourceVersionState::Discarded),
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref_from_version(&version, UI_SURFACE_KIND, "discarded")],
    }))
}

/// Validate one stored UI action and create the target invocation.
pub(in crate::engine) fn action_child_invocation(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<crate::engine::Invocation> {
    let surface_resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let surface_version_id = required_str(&invocation.payload, "surfaceVersionId")?;
    let action_id = required_str(&invocation.payload, "actionId")?;
    let idempotency_key = required_str(&invocation.payload, "idempotencyKey")?;
    if idempotency_key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "ui action submission requires idempotencyKey".to_owned(),
        ));
    }
    let inspection =
        host.inspect_resource(surface_resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: surface_resource_id.to_owned(),
            })?;
    ensure_ui_surface(&inspection)?;
    ensure_surface_active(&inspection)?;
    let current_version_id = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "ui_surface {surface_resource_id} has no current version"
            ))
        })?;
    if current_version_id != surface_version_id {
        return Err(EngineError::PolicyViolation(format!(
            "stale ui_surface version: expected {surface_version_id}, current {current_version_id}"
        )));
    }
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == surface_version_id)
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource_version",
            id: surface_version_id.to_owned(),
        })?;
    if version.state != EngineResourceVersionState::Available {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface version {surface_version_id} is not available"
        )));
    }
    let surface = &version.payload;
    ensure_not_expired(
        surface.get("expiresAt").and_then(Value::as_str),
        "ui_surface",
    )?;
    let action = surface_action(surface, action_id)?;
    ensure_not_expired(action.get("expiresAt").and_then(Value::as_str), "ui action")?;
    let target = validate_action_target(host, invocation, action)?;
    validate_required_grant(action, invocation)?;
    let input = invocation
        .payload
        .get("userInput")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let input_schema = action
        .get("inputSchema")
        .ok_or_else(|| EngineError::PolicyViolation("ui action requires inputSchema".to_owned()))?;
    schema::validate_payload(&target.id, "ui_action_input", input_schema, &input)?;
    let target_payload = render_payload_template(
        action.get("payloadTemplate").ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires payloadTemplate".to_owned())
        })?,
        &input,
        surface_resource_id,
        surface_version_id,
        action_id,
        idempotency_key,
    )?;
    let child_context = invocation
        .causal_context
        .clone()
        .with_parent_invocation(invocation.id.clone())
        .with_idempotency_key(idempotency_key.to_owned())
        .with_runtime_metadata("ui.surfaceResourceId", surface_resource_id.to_owned())
        .with_runtime_metadata("ui.surfaceVersionId", surface_version_id.to_owned())
        .with_runtime_metadata("ui.actionId", action_id.to_owned());
    let mut child =
        crate::engine::Invocation::new_sync(target.id.clone(), target_payload, child_context);
    child.expected_function_revision = Some(target.revision);
    Ok(child)
}

/// Wrap a child result as a `ui::submit_action` response.
#[must_use]
pub(in crate::engine) fn submit_action_result_value(
    invocation: &crate::engine::Invocation,
    child_result: &crate::engine::InvocationResult,
) -> Value {
    json!({
        "surfaceResourceId": invocation.payload.get("surfaceResourceId").cloned().unwrap_or(Value::Null),
        "surfaceVersionId": invocation.payload.get("surfaceVersionId").cloned().unwrap_or(Value::Null),
        "actionId": invocation.payload.get("actionId").cloned().unwrap_or(Value::Null),
        "targetFunctionId": child_result.function_id.as_str(),
        "childInvocationId": child_result.invocation_id.as_str(),
        "result": child_result.value.clone().unwrap_or_else(|| json!({})),
    })
}

fn validate_surface_targets(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    surface: &Value,
) -> Result<()> {
    let actions = surface
        .get("actions")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui_surface actions must be an array".to_owned())
        })?;
    for action in actions {
        let _ = validate_action_target(host, invocation, action)?;
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct SurfaceAuthoringRequest {
    target_type: String,
    target_id: String,
    purpose: String,
    layout_profile: String,
    expected_target_revision: Option<u64>,
    existing_surface_resource_id: Option<String>,
    expected_current_version_id: Option<String>,
    resource_id: Option<String>,
    max_preview_bytes: usize,
    expires_at: String,
    refresh_policy: Value,
    links: Vec<Value>,
}

struct AuthoredSurface {
    surface: Value,
}

impl SurfaceAuthoringRequest {
    fn from_invocation(invocation: &crate::engine::Invocation) -> Result<Self> {
        let target_type = required_string_owned(&invocation.payload, "targetType")?;
        ensure_supported_target_type(&target_type)?;
        let target_id = required_string_owned(&invocation.payload, "targetId")?;
        let purpose = optional_string(invocation.payload.get("purpose"))?
            .unwrap_or_else(|| format!("Inspect {target_type} {target_id}"));
        let layout_profile = optional_string(invocation.payload.get("layoutProfile"))?
            .unwrap_or_else(|| "compact".to_owned());
        let max_preview_bytes = optional_u64(invocation.payload.get("maxPreviewBytes"))?
            .unwrap_or(1024)
            .min(16 * 1024) as usize;
        let expires_at = optional_string(invocation.payload.get("expiresAt"))?
            .unwrap_or_else(default_expires_at);
        ensure_not_expired(Some(&expires_at), "ui_surface")?;
        Ok(Self {
            target_type,
            target_id,
            purpose,
            layout_profile,
            expected_target_revision: optional_u64(
                invocation.payload.get("expectedTargetRevision"),
            )?,
            existing_surface_resource_id: optional_string(
                invocation.payload.get("existingSurfaceResourceId"),
            )?,
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?,
            resource_id: optional_string(invocation.payload.get("resourceId"))?,
            max_preview_bytes,
            expires_at,
            refresh_policy: invocation
                .payload
                .get("refreshPolicy")
                .cloned()
                .unwrap_or_else(|| json!({"mode": "manual"})),
            links: invocation
                .payload
                .get("links")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
        })
    }

    fn from_authoring_payload(payload: &Value) -> Result<Self> {
        let authoring = payload
            .get("authoring")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "ui::refresh_surface requires generated authoring metadata".to_owned(),
                )
            })?;
        if authoring.get("mode").and_then(Value::as_str) != Some(GENERATED_AUTHORING_MODE) {
            return Err(EngineError::PolicyViolation(
                "ui::refresh_surface requires generated authoring metadata".to_owned(),
            ));
        }
        let target_type = authoring
            .get("targetType")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EngineError::PolicyViolation("generated authoring requires targetType".to_owned())
            })?
            .to_owned();
        ensure_supported_target_type(&target_type)?;
        let target_id = authoring
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EngineError::PolicyViolation("generated authoring requires targetId".to_owned())
            })?
            .to_owned();
        Ok(Self {
            target_type,
            target_id,
            purpose: authoring
                .get("purpose")
                .and_then(Value::as_str)
                .unwrap_or("Refresh generated surface")
                .to_owned(),
            layout_profile: authoring
                .get("layoutProfile")
                .and_then(Value::as_str)
                .unwrap_or("compact")
                .to_owned(),
            expected_target_revision: authoring.get("targetRevision").and_then(Value::as_u64),
            existing_surface_resource_id: None,
            expected_current_version_id: None,
            resource_id: None,
            max_preview_bytes: authoring
                .get("maxPreviewBytes")
                .and_then(Value::as_u64)
                .unwrap_or(1024)
                .min(16 * 1024) as usize,
            expires_at: payload
                .get("expiresAt")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .unwrap_or_else(default_expires_at),
            refresh_policy: payload
                .get("refreshPolicy")
                .cloned()
                .unwrap_or_else(|| json!({"mode": "manual"})),
            links: payload
                .get("bindings")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
        })
    }
}

fn author_surface_for_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    refreshed_from_version_id: Option<&str>,
) -> Result<AuthoredSurface> {
    let projection = target_projection(host, invocation, request)?;
    if let Some(expected) = request.expected_target_revision
        && projection.revision != expected
    {
        return Err(EngineError::StaleFunctionRevision {
            function_id: format!("{}:{}", request.target_type, request.target_id),
            expected,
            actual: projection.revision,
        });
    }
    let projection_hash = hash_json(&projection.graph)?;
    let mut bindings = vec![json!({
        "targetType": request.target_type,
        "targetId": request.target_id,
        "role": "target",
        "label": projection.title,
    })];
    for link in &request.links {
        if !bindings.iter().any(|binding| binding == link) {
            bindings.push(link.clone());
        }
    }
    let surface_id = format!(
        "generated.{}.{}",
        request.target_type,
        slug(&request.target_id)
    );
    let mut surface = json!({
        "surfaceId": surface_id,
        "title": projection.title,
        "purpose": request.purpose,
        "catalog": {"id": "tron.ui.catalog.core.v1", "revision": UI_CATALOG_REVISION},
        "layout": layout_for_projection(&projection),
        "bindings": bindings,
        "actions": generated_actions(host, invocation, request)?,
        "redactionPolicy": {"mode": "redacted"},
        "expiresAt": request.expires_at,
        "refreshPolicy": request.refresh_policy,
        "authoring": {
            "mode": GENERATED_AUTHORING_MODE,
            "targetType": request.target_type,
            "targetId": request.target_id,
            "purpose": request.purpose,
            "layoutProfile": request.layout_profile,
            "targetRevision": projection.revision,
            "catalogRevision": host.catalog_revision().0,
            "projectionHash": projection_hash,
            "maxPreviewBytes": request.max_preview_bytes,
            "createdByInvocationId": invocation.id.as_str(),
        }
    });
    if let Some(version_id) = refreshed_from_version_id {
        surface["authoring"]["refreshedFromVersionId"] = json!(version_id);
    }
    validate_surface_targets(host, invocation, &surface)?;
    validate_ui_surface_payload(&surface)?;
    Ok(AuthoredSurface { surface })
}

struct TargetProjection {
    title: String,
    summary: String,
    revision: u64,
    graph: Value,
}

fn target_projection(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    match request.target_type.as_str() {
        "worker" => {
            let worker_id = WorkerId::new(request.target_id.clone())?;
            let worker = host.inspect_worker(&worker_id)?;
            let functions = host
                .discover_functions(&FunctionQuery {
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .filter(|function| function.owner_worker == worker_id)
                .collect::<Vec<_>>();
            Ok(TargetProjection {
                title: format!("Worker {}", worker.id.as_str()),
                summary: format!("{} capabilities", functions.len()),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"worker": worker, "capabilities": functions}),
                    request.max_preview_bytes,
                ),
            })
        }
        "capability" => {
            let function = host
                .discover_functions(&FunctionQuery {
                    actor: Some(actor_context(invocation)),
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .find(|function| function.id.as_str() == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "function",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Capability {}", function.id.as_str()),
                summary: function.description.clone(),
                revision: function.revision.0,
                graph: bounded_json(json!({"capability": function}), request.max_preview_bytes),
            })
        }
        "goal" | "resource" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            let summary = format!(
                "{} / {}",
                inspection.resource.kind, inspection.resource.lifecycle
            );
            Ok(TargetProjection {
                title: format!("Resource {}", inspection.resource.resource_id),
                summary,
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"resource": inspection}), request.max_preview_bytes),
            })
        }
        "package" => {
            let resource_id = if request.target_id.starts_with("worker-package:") {
                request.target_id.clone()
            } else {
                format!("worker-package:{}", request.target_id)
            };
            let inspection =
                host.inspect_resource(&resource_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "resource",
                        id: resource_id.clone(),
                    })?;
            if inspection.resource.kind != "worker_package" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {resource_id} is {}, expected worker_package",
                    inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Package {}", request.target_id),
                summary: format!(
                    "{} / {}",
                    inspection.resource.kind, inspection.resource.lifecycle
                ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"package": inspection}), request.max_preview_bytes),
            })
        }
        "module_config" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            if inspection.resource.kind != "module_config" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {} is {}, expected module_config",
                    request.target_id, inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Module Config {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"moduleConfig": inspection}),
                    request.max_preview_bytes,
                ),
            })
        }
        "activation" => {
            let resource_id = if request.target_id.starts_with("activation:") {
                request.target_id.clone()
            } else {
                format!("activation:{}", request.target_id)
            };
            let inspection =
                host.inspect_resource(&resource_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "resource",
                        id: resource_id.clone(),
                    })?;
            if inspection.resource.kind != "activation_record" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {resource_id} is {}, expected activation_record",
                    inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Activation {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"activation": inspection}), request.max_preview_bytes),
            })
        }
        "invocation" => {
            let record = host
                .invocations()
                .into_iter()
                .find(|record| record.invocation_id.as_str() == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "invocation",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Invocation {}", record.function_id.as_str()),
                summary: record
                    .error
                    .as_ref()
                    .map_or_else(|| "completed".to_owned(), |_| "failed".to_owned()),
                revision: record.function_revision.0,
                graph: bounded_json(
                    json!({"invocation": invocation_record_value(&record, false)}),
                    request.max_preview_bytes,
                ),
            })
        }
        "grant" => {
            let grant_id = crate::engine::ids::AuthorityGrantId::new(request.target_id.clone())?;
            let grant = host
                .inspect_grant(&grant_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "grant",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Grant {}", grant.grant_id.as_str()),
                summary: format!("{:?} / max {:?}", grant.lifecycle, grant.max_risk),
                revision: grant.revision,
                graph: bounded_json(json!({"grant": grant}), request.max_preview_bytes),
            })
        }
        "approval" => {
            let record = host
                .approval_records(None, invocation.causal_context.session_id.as_deref(), 500)?
                .into_iter()
                .find(|record| record.approval_id == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "approval",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Approval {}", record.approval_id),
                summary: format!("{:?} {}", record.status, record.function_id.as_str()),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"approval": record}), request.max_preview_bytes),
            })
        }
        "queue" => {
            let item = host
                .queue_items("engine", 500)?
                .into_iter()
                .find(|item| {
                    item.receipt_id == request.target_id || item.queue == request.target_id
                })
                .ok_or_else(|| EngineError::NotFound {
                    kind: "queue_item",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Queue {}", item.receipt_id),
                summary: format!("{:?} {}", item.status, item.function_id.as_str()),
                revision: item
                    .target_revision
                    .map_or(host.catalog_revision().0, |revision| revision.0),
                graph: bounded_json(json!({"queue": item}), request.max_preview_bytes),
            })
        }
        "lease" => {
            let lease =
                host.resource_lease(&request.target_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "lease",
                        id: request.target_id.clone(),
                    })?;
            Ok(TargetProjection {
                title: format!("Lease {}", lease.lease_id),
                summary: format!(
                    "{:?} {}:{}",
                    lease.status, lease.resource_kind, lease.resource_id
                ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"lease": lease}), request.max_preview_bytes),
            })
        }
        "storage" => {
            let storage = host.storage_stats().ok().map(|stats| json!(stats));
            Ok(TargetProjection {
                title: "Storage".to_owned(),
                summary: storage
                    .as_ref()
                    .and_then(|value| value.get("databaseBytes").and_then(Value::as_u64))
                    .map_or_else(
                        || "storage stats unavailable".to_owned(),
                        |bytes| format!("{bytes} database bytes"),
                    ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"storage": storage}), request.max_preview_bytes),
            })
        }
        "integrity" => {
            let damaged = host.list_resources(crate::engine::resources::ListResources {
                kind: None,
                scope: None,
                lifecycle: Some("damaged".to_owned()),
                limit: 50,
            })?;
            Ok(TargetProjection {
                title: "Integrity".to_owned(),
                summary: format!("{} damaged resources", damaged.len()),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"damagedResources": damaged}),
                    request.max_preview_bytes,
                ),
            })
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported ui target type {other}"
        ))),
    }
}

fn layout_for_projection(projection: &TargetProjection) -> Value {
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": [
            {"type": "Heading", "props": {"text": projection.title}},
            {"type": "Text", "props": {"text": projection.summary}},
            {"type": "Monospace", "props": {"text": projection.graph.to_string()}},
            {"type": "Button", "props": {"label": "Refresh", "actionId": "refresh-surface"}}
        ]
    })
}

fn generated_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<Vec<Value>> {
    let functions = host.discover_functions(&FunctionQuery {
        actor: Some(actor_context(invocation)),
        include_internal: true,
        ..FunctionQuery::default()
    });
    let refresh = functions
        .iter()
        .find(|function| function.id.as_str() == REFRESH_SURFACE_FUNCTION)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: REFRESH_SURFACE_FUNCTION.to_owned(),
        })?;
    let mut actions = vec![json!({
        "actionId": "refresh-surface",
        "label": "Refresh",
        "targetFunctionId": REFRESH_SURFACE_FUNCTION,
        "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
        "payloadTemplate": {
            "surfaceResourceId": "${surface.resourceId}",
            "expectedCurrentVersionId": "${surface.versionId}"
        },
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&refresh.risk_level),
        "approvalPolicy": {"required": refresh.required_authority.approval_required},
        "targetRevision": refresh.revision.0,
        "expiresAt": default_expires_at()
    })];
    if request.target_type == "package" {
        if let Some(inspect_package) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::inspect_package")
        {
            actions.push(json!({
                "actionId": "inspect-package",
                "label": "Inspect Package",
                "targetFunctionId": "module::inspect_package",
                "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                "payloadTemplate": {
                    "packageId": request.target_id.strip_prefix("worker-package:").unwrap_or(&request.target_id)
                },
                "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                "requiredRisk": risk_label(&inspect_package.risk_level),
                "approvalPolicy": {"required": inspect_package.required_authority.approval_required},
                "targetRevision": inspect_package.revision.0,
                "expiresAt": default_expires_at()
            }));
        }
        if let Some(verify_integrity) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::verify_integrity")
        {
            let resource_id = if request.target_id.starts_with("worker-package:") {
                request.target_id.clone()
            } else {
                format!("worker-package:{}", request.target_id)
            };
            if let Some(inspection) = host.inspect_resource(&resource_id)?
                && let Some(version_id) = inspection.resource.current_version_id
            {
                actions.push(json!({
                    "actionId": "verify-package-integrity",
                    "label": "Verify Integrity",
                    "targetFunctionId": "module::verify_integrity",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_integrity.risk_level),
                    "approvalPolicy": {"required": verify_integrity.required_authority.approval_required},
                    "targetRevision": verify_integrity.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
        let resource_id = if request.target_id.starts_with("worker-package:") {
            request.target_id.clone()
        } else {
            format!("worker-package:{}", request.target_id)
        };
        if let Some(inspection) = host.inspect_resource(&resource_id)?
            && let Some(version_id) = inspection.resource.current_version_id.clone()
        {
            let manifest = current_payload(&inspection).unwrap_or_else(|| json!({}));
            if let Some(verify_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::verify_source")
            {
                actions.push(json!({
                    "actionId": "verify-package-source",
                    "label": "Verify Source",
                    "targetFunctionId": "module::verify_source",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "on_demand"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_source.risk_level),
                    "approvalPolicy": {"required": verify_source.required_authority.approval_required},
                    "targetRevision": verify_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(register_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::register_source")
            {
                if manifest
                    .get("sourceProvenance")
                    .and_then(|source| source.get("kind"))
                    .and_then(Value::as_str)
                    == Some("local_digest_pinned")
                {
                    actions.push(json!({
                        "actionId": "register-local-package-source",
                        "label": "Register Source",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "local_digest_source",
                            "scope": "system",
                            "sourceDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                            "sourceRef": manifest.get("sourceRef").cloned().unwrap_or_else(|| json!({})),
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
                if manifest
                    .get("signature")
                    .is_some_and(|value| !value.is_null())
                {
                    actions.push(json!({
                        "actionId": "register-ed25519-trust-root",
                        "label": "Register Trust Root",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["publicKey", "keyId", "reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "publicKey": {"type": "string"},
                                "keyId": {"type": "string"},
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "ed25519_trust_root",
                            "scope": "system",
                            "algorithm": "ed25519",
                            "publicKey": "${input.publicKey}",
                            "keyId": "${input.keyId}",
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "trustTierCeiling": "signed_local",
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
            }
            if manifest
                .get("signature")
                .is_some_and(|value| !value.is_null())
                && let Some(verify_signature) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::verify_signature")
            {
                actions.push(json!({
                    "actionId": "verify-package-signature",
                    "label": "Verify Signature",
                    "targetFunctionId": "module::verify_signature",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_signature.risk_level),
                    "approvalPolicy": {"required": verify_signature.required_authority.approval_required},
                    "targetRevision": verify_signature.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(audit_policy) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::audit_policy")
            {
                actions.push(json!({
                    "actionId": "audit-package-policy",
                    "label": "Audit Policy",
                    "targetFunctionId": "module::audit_policy",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&audit_policy.risk_level),
                    "approvalPolicy": {"required": audit_policy.required_authority.approval_required},
                    "targetRevision": audit_policy.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_policy_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_policy_audit")
            {
                actions.push(json!({
                    "actionId": "record-package-policy-audit",
                    "label": "Record Audit",
                    "targetFunctionId": "module::record_policy_audit",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_policy_audit.risk_level),
                    "approvalPolicy": {"required": record_policy_audit.required_authority.approval_required},
                    "targetRevision": record_policy_audit.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(reconcile_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::reconcile_trust")
            {
                actions.push(json!({
                    "actionId": "reconcile-package-trust",
                    "label": "Reconcile Trust",
                    "targetFunctionId": "module::reconcile_trust",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason"],
                        "additionalProperties": false,
                        "properties": {"reason": {"type": "string"}}
                    },
                    "payloadTemplate": {
                        "scope": "system",
                        "packageResourceId": resource_id,
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&reconcile_trust.risk_level),
                    "approvalPolicy": {"required": reconcile_trust.required_authority.approval_required},
                    "targetRevision": reconcile_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(run_conformance) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::run_conformance")
            {
                actions.push(json!({
                    "actionId": "run-package-conformance",
                    "label": "Run Conformance",
                    "targetFunctionId": "module::run_conformance",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "static"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&run_conformance.risk_level),
                    "approvalPolicy": {"required": run_conformance.required_authority.approval_required},
                    "targetRevision": run_conformance.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if manifest
                .get("sourceProvenance")
                .and_then(|source| source.get("kind"))
                .and_then(Value::as_str)
                == Some("local_digest_pinned")
                && manifest.get("sourceTrustStatus").and_then(Value::as_str) == Some("verified")
                && let Some(approve_source) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::approve_source")
            {
                actions.push(json!({
                    "actionId": "approve-package-source",
                    "label": "Approve Source",
                    "targetFunctionId": "module::approve_source",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason", "expiresAt"],
                        "additionalProperties": false,
                        "properties": {
                            "reason": {"type": "string"},
                            "expiresAt": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "packageDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                        "packageId": manifest.get("packageId").cloned().unwrap_or(Value::Null),
                        "scope": "system",
                        "trustTierCeiling": "local_digest_pinned",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "expiresAt": "${input.expiresAt}",
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&approve_source.risk_level),
                    "approvalPolicy": {"required": approve_source.required_authority.approval_required},
                    "targetRevision": approve_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    if request.target_type == "activation" {
        let resource_id = if request.target_id.starts_with("activation:") {
            request.target_id.clone()
        } else {
            format!("activation:{}", request.target_id)
        };
        let version_id = host
            .inspect_resource(&resource_id)?
            .and_then(|inspection| inspection.resource.current_version_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        for (action_id, label, target_function, payload) in [
            (
                "check-activation-health",
                "Check Health",
                "module::check_health",
                json!({
                    "activationResourceId": resource_id,
                    "activationVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "mode": "on_demand"
                }),
            ),
            (
                "verify-activation-integrity",
                "Verify Integrity",
                "module::verify_integrity",
                json!({
                    "targetType": "activation_record",
                    "resourceId": resource_id,
                    "resourceVersionId": version_id,
                    "expectedCurrentVersionId": version_id
                }),
            ),
            (
                "recover-activation",
                "Recover",
                "module::recover_activation",
                json!({
                    "activationResourceId": resource_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "operator requested recovery from generated surface"
                }),
            ),
        ] {
            if let Some(target) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&target.risk_level),
                    "approvalPolicy": {"required": target.required_authority.approval_required},
                    "targetRevision": target.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    Ok(actions)
}

fn validate_action_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    action: &Value,
) -> Result<FunctionDefinition> {
    let target_id = action
        .get("targetFunctionId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires targetFunctionId".to_owned())
        })?;
    if target_id == SUBMIT_ACTION_FUNCTION {
        return Err(EngineError::PolicyViolation(
            "ui actions cannot target ui::submit_action".to_owned(),
        ));
    }
    let target_id = FunctionId::new(target_id.to_owned())?;
    let target = host
        .discover_functions(&FunctionQuery {
            actor: Some(actor_context(invocation)),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .into_iter()
        .find(|function| function.id == target_id)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: target_id.to_string(),
        })?;
    let expected_revision = action
        .get("targetRevision")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires targetRevision".to_owned())
        })?;
    if target.revision.0 != expected_revision {
        return Err(EngineError::StaleFunctionRevision {
            function_id: target.id.to_string(),
            expected: expected_revision,
            actual: target.revision.0,
        });
    }
    if target.effect_class.requires_idempotency() && target.idempotency.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "ui action target {} is mutating without idempotency",
            target.id
        )));
    }
    let declared_risk = action
        .get("requiredRisk")
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::PolicyViolation("ui action requires requiredRisk".to_owned()))
        .and_then(parse_risk)?;
    if target.risk_level > declared_risk {
        return Err(EngineError::PolicyViolation(format!(
            "ui action declared risk {:?} below target {} risk {:?}",
            declared_risk, target.id, target.risk_level
        )));
    }
    validate_action_payload_template_against_target_schema(action, &target)?;
    Ok(target)
}

fn validate_action_payload_template_against_target_schema(
    action: &Value,
    target: &FunctionDefinition,
) -> Result<()> {
    let Some(schema) = &target.request_schema else {
        return Ok(());
    };
    let template = action.get("payloadTemplate").ok_or_else(|| {
        EngineError::PolicyViolation("ui action requires payloadTemplate".to_owned())
    })?;
    validate_template_node(&target.id, schema, template, "$")
}

fn validate_template_node(
    target_id: &FunctionId,
    schema: &Value,
    template: &Value,
    path: &str,
) -> Result<()> {
    let schema_object = schema
        .as_object()
        .ok_or_else(|| EngineError::InvalidSchema {
            function_id: target_id.to_string(),
            direction: "ui_action_target_request",
            message: format!("{path} must be an object"),
        })?;
    if template
        .as_str()
        .is_some_and(|text| text.starts_with("${") && text.ends_with('}'))
    {
        return Ok(());
    }
    if schema_object
        .get("type")
        .is_some_and(|schema_type| schema_type == "object")
    {
        let template_object = template.as_object().ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "ui action payloadTemplate {path} must be an object for target {target_id}"
            ))
        })?;
        let properties = schema_object
            .get("properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        if schema_object
            .get("additionalProperties")
            .and_then(Value::as_bool)
            == Some(false)
        {
            for key in template_object.keys() {
                if !properties.contains_key(key) {
                    return Err(EngineError::PolicyViolation(format!(
                        "ui action payloadTemplate {path}.{key} is not accepted by target {target_id}"
                    )));
                }
            }
        }
        if let Some(required) = schema_object.get("required").and_then(Value::as_array) {
            for field in required {
                let field = field.as_str().ok_or_else(|| EngineError::InvalidSchema {
                    function_id: target_id.to_string(),
                    direction: "ui_action_target_request",
                    message: format!("{path}.required entries must be strings"),
                })?;
                if !template_object.contains_key(field) {
                    return Err(EngineError::PolicyViolation(format!(
                        "ui action payloadTemplate missing required target field {field}"
                    )));
                }
            }
        }
        for (key, child_schema) in properties {
            if let Some(child_template) = template_object.get(&key) {
                validate_template_node(
                    target_id,
                    &child_schema,
                    child_template,
                    &format!("{path}.{key}"),
                )?;
            }
        }
        return Ok(());
    }
    if !template_contains_placeholder(template) {
        schema::validate_payload(target_id, "ui_action_target_request", schema, template)?;
    }
    Ok(())
}

fn template_contains_placeholder(value: &Value) -> bool {
    match value {
        Value::String(text) => text.starts_with("${") && text.ends_with('}'),
        Value::Array(items) => items.iter().any(template_contains_placeholder),
        Value::Object(object) => object.values().any(template_contains_placeholder),
        _ => false,
    }
}

fn actor_context(invocation: &crate::engine::Invocation) -> ActorContext {
    ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: invocation.causal_context.actor_kind.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: invocation.causal_context.authority_scopes.clone(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    }
}

fn validate_required_grant(action: &Value, invocation: &crate::engine::Invocation) -> Result<()> {
    let required = action
        .get("requiredGrant")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if required == invocation.causal_context.authority_grant_id.as_str() {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "ui action requires grant {required}"
        )))
    }
}

fn render_payload_template(
    template: &Value,
    input: &Value,
    surface_resource_id: &str,
    surface_version_id: &str,
    action_id: &str,
    idempotency_key: &str,
) -> Result<Value> {
    match template {
        Value::String(text) => match text.as_str() {
            "${surface.resourceId}" => Ok(json!(surface_resource_id)),
            "${surface.versionId}" => Ok(json!(surface_version_id)),
            "${action.id}" => Ok(json!(action_id)),
            "${submission.idempotencyKey}" => Ok(json!(idempotency_key)),
            value if value.starts_with("${input.") && value.ends_with('}') => {
                let path = &value["${input.".len()..value.len() - 1];
                input.get(path).cloned().ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "ui action input template references missing field {path}"
                    ))
                })
            }
            value if value.starts_with("${") && value.ends_with('}') => {
                Err(EngineError::PolicyViolation(format!(
                    "unsupported ui action payloadTemplate placeholder {value}"
                )))
            }
            _ => Ok(template.clone()),
        },
        Value::Array(items) => items
            .iter()
            .map(|item| {
                render_payload_template(
                    item,
                    input,
                    surface_resource_id,
                    surface_version_id,
                    action_id,
                    idempotency_key,
                )
            })
            .collect::<Result<Vec<_>>>()
            .map(Value::Array),
        Value::Object(object) => {
            let mut rendered = serde_json::Map::new();
            for (key, value) in object {
                rendered.insert(
                    key.clone(),
                    render_payload_template(
                        value,
                        input,
                        surface_resource_id,
                        surface_version_id,
                        action_id,
                        idempotency_key,
                    )?,
                );
            }
            Ok(Value::Object(rendered))
        }
        _ => Ok(template.clone()),
    }
}

fn normalized_surface_payload(invocation: &crate::engine::Invocation) -> Result<Value> {
    let mut surface = invocation.payload.get("surface").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{} requires surface", invocation.function_id))
    })?;
    if let Some(links) = invocation.payload.get("links").and_then(Value::as_array) {
        let bindings = surface
            .get_mut("bindings")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                EngineError::PolicyViolation("ui_surface bindings must be an array".to_owned())
            })?;
        bindings.extend(links.iter().cloned());
    }
    validate_ui_surface_payload(&surface)?;
    Ok(surface)
}

fn resource_scope_from_payload(
    invocation: &crate::engine::Invocation,
) -> Result<EngineResourceScope> {
    match optional_string(invocation.payload.get("scope"))?
        .unwrap_or_else(|| "session".to_owned())
        .as_str()
    {
        "system" => Ok(EngineResourceScope::System),
        "workspace" => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace scoped resource requires workspaceId".to_owned(),
                    )
                })?;
            if workspace_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "workspaceId must not be empty".to_owned(),
                ));
            }
            Ok(EngineResourceScope::Workspace(workspace_id))
        }
        "session" => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session scoped resource requires sessionId".to_owned(),
                    )
                })?;
            if session_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "sessionId must not be empty".to_owned(),
                ));
            }
            Ok(EngineResourceScope::Session(session_id))
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported resource scope {other}"
        ))),
    }
}

fn surface_lifecycle(invocation: &crate::engine::Invocation, default: &str) -> Result<String> {
    let lifecycle =
        optional_string(invocation.payload.get("lifecycle"))?.unwrap_or_else(|| default.to_owned());
    if matches!(
        lifecycle.as_str(),
        "draft" | "active" | "superseded" | "expired" | "discarded" | "damaged"
    ) {
        Ok(lifecycle)
    } else {
        Err(EngineError::PolicyViolation(format!(
            "unsupported ui_surface lifecycle {lifecycle}"
        )))
    }
}

fn ensure_ui_surface(inspection: &EngineResourceInspection) -> Result<()> {
    if inspection.resource.kind == UI_SURFACE_KIND {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected ui_surface",
            inspection.resource.resource_id, inspection.resource.kind
        )))
    }
}

fn ensure_surface_active(inspection: &EngineResourceInspection) -> Result<()> {
    match inspection.resource.lifecycle.as_str() {
        "active" | "draft" => Ok(()),
        lifecycle => Err(EngineError::PolicyViolation(format!(
            "ui_surface {} is {lifecycle}",
            inspection.resource.resource_id
        ))),
    }
}

fn current_payload(inspection: &EngineResourceInspection) -> Option<Value> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| version.payload.clone())
}

fn surface_action<'a>(surface: &'a Value, action_id: &str) -> Result<&'a Value> {
    surface
        .get("actions")
        .and_then(Value::as_array)
        .and_then(|actions| {
            actions
                .iter()
                .find(|action| action.get("actionId").and_then(Value::as_str) == Some(action_id))
        })
        .ok_or_else(|| EngineError::NotFound {
            kind: "ui_action",
            id: action_id.to_owned(),
        })
}

fn ensure_not_expired(expires_at: Option<&str>, subject: &str) -> Result<()> {
    let Some(expires_at) = expires_at else {
        return Err(EngineError::PolicyViolation(format!(
            "{subject} requires expiresAt"
        )));
    };
    let expires_at = DateTime::parse_from_rfc3339(expires_at)
        .map_err(|error| {
            EngineError::PolicyViolation(format!("{subject} expiresAt invalid: {error}"))
        })?
        .with_timezone(&Utc);
    if expires_at <= Utc::now() {
        Err(EngineError::PolicyViolation(format!(
            "{subject} is expired"
        )))
    } else {
        Ok(())
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported ui action risk {value}"
        ))),
    }
}

fn risk_label(risk: &RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

struct SurfaceValidation {
    state: &'static str,
    diagnostics: Vec<Value>,
}

fn surface_validation_state(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    inspection: &Option<EngineResourceInspection>,
) -> SurfaceValidation {
    let Some(inspection) = inspection else {
        return SurfaceValidation {
            state: "invalid",
            diagnostics: vec![
                json!({"code": "missing_surface", "message": "ui_surface resource does not exist"}),
            ],
        };
    };
    if let Err(error) = ensure_ui_surface(inspection) {
        return validation_error("invalid", "wrong_kind", error);
    }
    match inspection.resource.lifecycle.as_str() {
        "expired" => {
            return SurfaceValidation {
                state: "expired",
                diagnostics: vec![
                    json!({"code": "expired_lifecycle", "message": "ui_surface lifecycle is expired"}),
                ],
            };
        }
        "damaged" | "discarded" => {
            return SurfaceValidation {
                state: "damaged",
                diagnostics: vec![
                    json!({"code": "unavailable_lifecycle", "message": format!("ui_surface lifecycle is {}", inspection.resource.lifecycle)}),
                ],
            };
        }
        _ => {}
    }
    let Some(current_version_id) = inspection.resource.current_version_id.as_deref() else {
        return SurfaceValidation {
            state: "invalid",
            diagnostics: vec![
                json!({"code": "missing_current_version", "message": "ui_surface has no current version"}),
            ],
        };
    };
    let Some(version) = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current_version_id)
    else {
        return SurfaceValidation {
            state: "damaged",
            diagnostics: vec![
                json!({"code": "missing_current_version_record", "message": "current ui_surface version is missing"}),
            ],
        };
    };
    if version.state != EngineResourceVersionState::Available {
        return SurfaceValidation {
            state: "damaged",
            diagnostics: vec![
                json!({"code": "unavailable_version", "message": format!("current ui_surface version is {:?}", version.state)}),
            ],
        };
    }
    let payload = &version.payload;
    if let Err(error) = validate_ui_surface_payload(payload) {
        return validation_error("invalid", "invalid_payload", error);
    }
    if DateTime::parse_from_rfc3339(
        payload
            .get("expiresAt")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )
    .map(|expires_at| expires_at.with_timezone(&Utc) <= Utc::now())
    .unwrap_or(true)
    {
        return SurfaceValidation {
            state: "expired",
            diagnostics: vec![
                json!({"code": "expired_surface", "message": "ui_surface expiresAt is expired or invalid"}),
            ],
        };
    }
    if let Some(actions) = payload.get("actions").and_then(Value::as_array) {
        for action in actions {
            if DateTime::parse_from_rfc3339(
                action
                    .get("expiresAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
            .map(|expires_at| expires_at.with_timezone(&Utc) <= Utc::now())
            .unwrap_or(true)
            {
                return SurfaceValidation {
                    state: "expired",
                    diagnostics: vec![
                        json!({"code": "expired_action", "message": "ui_surface action is expired or invalid"}),
                    ],
                };
            }
            if action
                .get("requiredGrant")
                .and_then(Value::as_str)
                .is_some_and(|required| {
                    required != invocation.causal_context.authority_grant_id.as_str()
                })
            {
                return SurfaceValidation {
                    state: "unauthorized",
                    diagnostics: vec![
                        json!({"code": "grant_mismatch", "message": "ui_surface action requires a different grant"}),
                    ],
                };
            }
            if let Err(error) = validate_action_target(host, invocation, action) {
                return match error {
                    EngineError::StaleFunctionRevision { .. } => {
                        validation_error("stale", "stale_action_target", error)
                    }
                    EngineError::NotFound { .. } => {
                        validation_error("invalid", "missing_action_target", error)
                    }
                    other => validation_error("invalid", "invalid_action_target", other),
                };
            }
        }
    }
    if let Some(authoring) = payload.get("authoring").and_then(Value::as_object)
        && authoring.get("mode").and_then(Value::as_str) == Some(GENERATED_AUTHORING_MODE)
    {
        match SurfaceAuthoringRequest::from_authoring_payload(payload).and_then(|request| {
            target_projection(host, invocation, &request).map(|target| (request, target))
        }) {
            Ok((_, target)) => {
                if authoring
                    .get("targetRevision")
                    .and_then(Value::as_u64)
                    .is_some_and(|revision| revision != target.revision)
                {
                    return SurfaceValidation {
                        state: "stale",
                        diagnostics: vec![
                            json!({"code": "stale_target_revision", "message": "generated ui_surface target revision drifted"}),
                        ],
                    };
                }
            }
            Err(error) => return validation_error("invalid", "invalid_authoring_target", error),
        }
    }
    if let Some(bindings) = payload.get("bindings").and_then(Value::as_array) {
        for binding in bindings {
            if let Err(error) = validate_binding_target(host, invocation, binding) {
                return validation_error("invalid", "dangling_binding", error);
            }
        }
    }
    SurfaceValidation {
        state: "valid",
        diagnostics: Vec::new(),
    }
}

fn validation_error(
    state: &'static str,
    code: &'static str,
    error: EngineError,
) -> SurfaceValidation {
    SurfaceValidation {
        state,
        diagnostics: vec![json!({"code": code, "message": error.to_string()})],
    }
}

fn validate_binding_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    binding: &Value,
) -> Result<()> {
    let Some(target_type) = binding.get("targetType").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(target_id) = binding.get("targetId").and_then(Value::as_str) else {
        return Ok(());
    };
    let request = SurfaceAuthoringRequest {
        target_type: target_type.to_owned(),
        target_id: target_id.to_owned(),
        purpose: "validate binding".to_owned(),
        layout_profile: "compact".to_owned(),
        expected_target_revision: None,
        existing_surface_resource_id: None,
        expected_current_version_id: None,
        resource_id: None,
        max_preview_bytes: 256,
        expires_at: default_expires_at(),
        refresh_policy: json!({"mode": "manual"}),
        links: Vec::new(),
    };
    target_projection(host, invocation, &request).map(|_| ())
}

fn current_version_hash(inspection: &EngineResourceInspection) -> Option<String> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| version.content_hash.clone())
}

fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .map(Some)
            .ok_or_else(|| EngineError::PolicyViolation("expected unsigned integer".to_owned())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected unsigned integer, got {other}"
        ))),
    }
}

fn default_expires_at() -> String {
    (Utc::now() + ChronoDuration::hours(1)).to_rfc3339()
}

fn ensure_supported_target_type(target_type: &str) -> Result<()> {
    if matches!(
        target_type,
        "worker"
            | "capability"
            | "goal"
            | "package"
            | "module_config"
            | "activation"
            | "resource"
            | "invocation"
            | "grant"
            | "approval"
            | "queue"
            | "lease"
            | "storage"
            | "integrity"
    ) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "unsupported ui target type {target_type}"
        )))
    }
}

fn deterministic_surface_resource_id(request: &SurfaceAuthoringRequest) -> String {
    format!(
        "ui-surface-{}-{}",
        request.target_type,
        slug(&request.target_id)
    )
}

fn slug(value: &str) -> String {
    let mut slug = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    while slug.contains("--") {
        slug = slug.replace("--", "-");
    }
    slug.trim_matches('-').chars().take(48).collect::<String>()
}

fn hash_json(value: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|error| EngineError::LedgerFailure {
        operation: "ui_surface.projection_hash",
        message: error.to_string(),
    })?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn bounded_json(value: Value, max_preview_bytes: usize) -> Value {
    let text = value.to_string();
    if text.len() <= max_preview_bytes {
        value
    } else {
        json!({
            "truncated": true,
            "preview": text.chars().take(max_preview_bytes).collect::<String>(),
        })
    }
}

fn action_summaries(payload: Option<&Value>) -> Value {
    let Some(actions) = payload
        .and_then(|payload| payload.get("actions"))
        .and_then(Value::as_array)
    else {
        return json!([]);
    };
    Value::Array(
        actions
            .iter()
            .map(|action| {
                json!({
                    "actionId": action.get("actionId").cloned().unwrap_or(Value::Null),
                    "label": action.get("label").cloned().unwrap_or(Value::Null),
                    "targetFunctionId": action.get("targetFunctionId").cloned().unwrap_or(Value::Null),
                    "targetRevision": action.get("targetRevision").cloned().unwrap_or(Value::Null),
                    "requiredRisk": action.get("requiredRisk").cloned().unwrap_or(Value::Null),
                    "expiresAt": action.get("expiresAt").cloned().unwrap_or(Value::Null),
                })
            })
            .collect(),
    )
}

fn surface_lineage(inspection: Option<&EngineResourceInspection>) -> Value {
    let Some(inspection) = inspection else {
        return json!({});
    };
    json!({
        "outgoingLinks": inspection.outgoing_links,
        "incomingLinks": inspection.incoming_links,
        "versionCount": inspection.versions.len(),
    })
}

fn resource_ref_from_resource(resource: &EngineResource, role: &str) -> Value {
    let mut value = json!({
        "resourceId": resource.resource_id.as_str(),
        "kind": resource.kind.as_str(),
        "role": role,
    });
    if let Some(version_id) = &resource.current_version_id {
        value["versionId"] = json!(version_id);
    }
    value
}

fn resource_ref_from_version(version: &EngineResourceVersion, kind: &str, role: &str) -> Value {
    json!({
        "resourceId": version.resource_id.as_str(),
        "kind": kind,
        "versionId": version.version_id.as_str(),
        "role": role,
        "contentHash": version.content_hash.as_str(),
    })
}

fn create_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surface"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "surface": {"type": "object"},
            "links": {"type": "array", "items": {"type": "object"}},
            "scope": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn surface_for_target_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {
                "type": "string",
                "enum": ["worker", "capability", "goal", "package", "module_config", "activation", "resource", "invocation", "grant", "approval", "queue", "lease", "storage", "integrity"]
            },
            "targetId": {"type": "string"},
            "purpose": {"type": "string"},
            "layoutProfile": {"type": "string"},
            "expectedTargetRevision": {"type": "integer"},
            "existingSurfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "resourceId": {"type": "string"},
            "maxPreviewBytes": {"type": "integer"},
            "expiresAt": {"type": "string"},
            "refreshPolicy": {"type": "object"},
            "links": {"type": "array", "items": {"type": "object"}},
            "scope": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn update_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "expectedCurrentVersionId", "surface"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "surface": {"type": "object"},
            "links": {"type": "array", "items": {"type": "object"}},
            "lifecycle": {"type": "string"}
        }
    })
}

fn refresh_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId", "expectedCurrentVersionId"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn expire_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn discard_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn submit_action_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId", "surfaceVersionId", "actionId", "userInput", "idempotencyKey"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "surfaceVersionId": {"type": "string"},
            "actionId": {"type": "string"},
            "userInput": {"type": "object"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn surface_resource_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "surface": {"type": "object"},
            "resource": {"type": "object"},
            "version": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn surface_version_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["version", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "surface": {"type": "object"},
            "version": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}
