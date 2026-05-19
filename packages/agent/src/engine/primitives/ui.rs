//! Generated UI primitive contracts and host-dispatched handlers.
//!
//! `ui_surface` is a resource kind. The `ui::*` capabilities are narrow
//! wrappers around the generic resource store plus the fixed component catalog.
//! They do not own durable state.

mod validation;

pub(in crate::engine) use validation::action_child_invocation;
use validation::{
    current_version_hash, surface_validation_state, validate_surface, validate_surface_targets,
};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::action_summary::with_stored_action_consequence;
use super::{
    PrimitiveFunctionRegistration, UI_WORKER_ID, host_dispatched_registration, optional_string,
    primitive_function, required_str, required_string_owned,
};
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::ids::FunctionId;
use crate::engine::primitives::runtime::{PrimitiveRuntimeHost, invocation_record_value};
use crate::engine::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion,
    EngineResourceVersionState, ListResources, UI_CATALOG_REVISION, UI_SURFACE_KIND,
    UpdateResource, ui_component_catalog, validate_ui_surface_payload,
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
const RESOURCE_COLLECTION_TARGET: &str = "resource_collection";
const PROMPT_SNIPPET_COLLECTION_TARGET: &str = "artifact:prompt-snippet";
const PROMPT_HISTORY_COLLECTION_TARGET: &str = "artifact:prompt-history";
const PROMPT_SNIPPET_RESOURCE_PREFIX: &str = "artifact:prompt-snippet:";
const PROMPT_HISTORY_RESOURCE_PREFIX: &str = "artifact:prompt-history:";
const PROMPT_SNIPPET_LAYOUT_PROFILE: &str = "prompt_library.snippets.v1";
const PROMPT_HISTORY_LAYOUT_PROFILE: &str = "prompt_library.history.v1";
const PROMPT_COLLECTION_LIMIT: usize = 25;

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
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
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
        "layout": layout_for_projection(request, &projection),
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
        RESOURCE_COLLECTION_TARGET => prompt_library_collection_projection(host, request),
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
        "decision" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            if inspection.resource.kind != "decision" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {} is {}, expected decision",
                    request.target_id, inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Decision {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"decision": inspection}), request.max_preview_bytes),
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

fn prompt_library_collection_projection(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    let (prefix, title, expected_profile, row_kind) = match request.target_id.as_str() {
        PROMPT_SNIPPET_COLLECTION_TARGET => (
            PROMPT_SNIPPET_RESOURCE_PREFIX,
            "Prompt Snippets",
            PROMPT_SNIPPET_LAYOUT_PROFILE,
            "snippet",
        ),
        PROMPT_HISTORY_COLLECTION_TARGET => (
            PROMPT_HISTORY_RESOURCE_PREFIX,
            "Prompt History",
            PROMPT_HISTORY_LAYOUT_PROFILE,
            "history",
        ),
        other => {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported resource_collection target {other}"
            )));
        }
    };
    if request.layout_profile != expected_profile {
        return Err(EngineError::PolicyViolation(format!(
            "resource_collection target {} requires layoutProfile {expected_profile}",
            request.target_id
        )));
    }

    let resources = host.list_resources(ListResources {
        kind: Some("artifact".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource.resource_id.starts_with(prefix)
            && resource.lifecycle != "discarded"
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let row = match row_kind {
            "snippet" => prompt_snippet_collection_row(&inspection, &payload, request),
            "history" => prompt_history_collection_row(&inspection, &payload, request),
            _ => None,
        };
        if let Some(row) = row {
            rows.push(row);
        }
    }
    rows.sort_by(|left, right| {
        right
            .get("sortKey")
            .and_then(Value::as_str)
            .cmp(&left.get("sortKey").and_then(Value::as_str))
            .then_with(|| {
                left.get("resourceId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("resourceId").and_then(Value::as_str))
            })
    });
    let truncated = rows.len() > PROMPT_COLLECTION_LIMIT;
    rows.truncate(PROMPT_COLLECTION_LIMIT);
    let summary = format!(
        "{} {}{}",
        rows.len(),
        if row_kind == "snippet" {
            "snippets"
        } else {
            "history entries"
        },
        if truncated { " shown" } else { "" }
    );
    Ok(TargetProjection {
        title: title.to_owned(),
        summary,
        revision: host.catalog_revision().0,
        graph: json!({
            "collection": {
                "targetId": request.target_id,
                "layoutProfile": request.layout_profile,
                "resourceKind": "artifact",
                "rowKind": row_kind,
                "rows": rows,
                "truncated": truncated,
                "limit": PROMPT_COLLECTION_LIMIT,
            }
        }),
    })
}

fn prompt_snippet_collection_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    request: &SurfaceAuthoringRequest,
) -> Option<Value> {
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| {
            inspection
                .resource
                .resource_id
                .strip_prefix(PROMPT_SNIPPET_RESOURCE_PREFIX)
        })?
        .to_owned();
    let name = bounded_prompt_preview(
        payload
            .get("name")
            .or_else(|| payload.get("title"))
            .and_then(Value::as_str)
            .unwrap_or("Untitled snippet"),
        request,
    );
    let text = bounded_prompt_preview(
        payload
            .get("text")
            .or_else(|| payload.get("body"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        request,
    );
    Some(json!({
        "id": id,
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "name": name,
        "text": text,
        "updatedAt": payload.get("updatedAt").cloned().unwrap_or(Value::Null),
        "sortKey": payload
            .get("updatedAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("createdAt").and_then(Value::as_str))
            .unwrap_or_default(),
    }))
}

fn prompt_history_collection_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    request: &SurfaceAuthoringRequest,
) -> Option<Value> {
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| {
            inspection
                .resource
                .resource_id
                .strip_prefix(PROMPT_HISTORY_RESOURCE_PREFIX)
        })?
        .to_owned();
    let text = bounded_prompt_preview(
        payload
            .get("text")
            .or_else(|| payload.get("body"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        request,
    );
    Some(json!({
        "id": id,
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "text": text,
        "lastUsedAt": payload.get("lastUsedAt").cloned().unwrap_or(Value::Null),
        "useCount": payload.get("useCount").cloned().unwrap_or_else(|| json!(1)),
        "sortKey": payload
            .get("lastUsedAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("firstUsedAt").and_then(Value::as_str))
            .unwrap_or_default(),
    }))
}

fn bounded_prompt_preview(text: &str, request: &SurfaceAuthoringRequest) -> String {
    if unsafe_prompt_preview_text(text) {
        return "[redacted]".to_owned();
    }
    let max_chars = request.max_preview_bytes.clamp(64, 512);
    if text.chars().count() <= max_chars {
        text.to_owned()
    } else {
        let mut preview = text.chars().take(max_chars).collect::<String>();
        preview.push_str("...");
        preview
    }
}

fn unsafe_prompt_preview_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("secret=")
        || lower.contains("api_key")
        || lower.contains("access_token")
        || lower.contains("private_key")
        || lower.contains("file://")
        || lower.contains("javascript:")
        || lower.contains("<script")
        || text.contains("sk-")
}

fn layout_for_projection(
    request: &SurfaceAuthoringRequest,
    projection: &TargetProjection,
) -> Value {
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        return prompt_collection_layout(request, projection);
    }
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

fn prompt_collection_layout(
    request: &SurfaceAuthoringRequest,
    projection: &TargetProjection,
) -> Value {
    let rows = projection
        .graph
        .pointer("/collection/rows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if request.layout_profile == PROMPT_SNIPPET_LAYOUT_PROFILE {
        return prompt_snippet_collection_layout(projection, &rows);
    }
    prompt_history_collection_layout(projection, &rows)
}

fn prompt_snippet_collection_layout(projection: &TargetProjection, rows: &[Value]) -> Value {
    let mut children = vec![
        json!({"type": "Heading", "props": {"text": projection.title}}),
        json!({"type": "Text", "props": {"text": projection.summary}}),
        json!({
            "type": "Disclosure",
            "props": {"title": "Create snippet", "open": false},
            "children": [
                {"type": "TextField", "props": {"name": "name", "label": "Name", "required": true}},
                {"type": "TextArea", "props": {"name": "text", "label": "Text", "required": true}},
                {"type": "Button", "props": {"label": "Create", "actionId": "create-snippet"}}
            ]
        }),
    ];
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No snippets",
                "message": "Create a snippet to make it available in the picker."
            }
        }));
    } else {
        for row in rows {
            let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let row_key = collection_row_key(resource_id);
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("name").and_then(Value::as_str).unwrap_or("Snippet"),
                    "open": false
                },
                "children": [
                    {"type": "ResourceRef", "props": {
                        "resourceId": resource_id,
                        "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                        "kind": "artifact",
                        "label": "Snippet resource"
                    }},
                    {"type": "TextField", "props": {
                        "name": format!("name_{row_key}"),
                        "label": "Name",
                        "value": row.get("name").cloned().unwrap_or(Value::Null),
                        "required": true
                    }},
                    {"type": "TextArea", "props": {
                        "name": format!("text_{row_key}"),
                        "label": "Text",
                        "value": row.get("text").cloned().unwrap_or(Value::Null),
                        "required": true
                    }},
                    {"type": "ButtonGroup", "props": {
                        "actions": [
                            format!("update-snippet-{row_key}"),
                            format!("delete-snippet-{row_key}")
                        ]
                    }}
                ]
            }));
        }
    }
    children.push(json!({
        "type": "Button",
        "props": {"label": "Refresh", "actionId": "refresh-surface"}
    }));
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

fn prompt_history_collection_layout(projection: &TargetProjection, rows: &[Value]) -> Value {
    let mut children = vec![
        json!({"type": "Heading", "props": {"text": projection.title}}),
        json!({"type": "Text", "props": {"text": projection.summary}}),
        json!({
            "type": "Confirmation",
            "props": {
                "title": "Clear history",
                "message": "Discard all prompt history artifacts.",
                "confirmActionId": "clear-history"
            }
        }),
    ];
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No history",
                "message": "Prompt history artifacts will appear here."
            }
        }));
    } else {
        for row in rows {
            let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let row_key = collection_row_key(resource_id);
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("text").and_then(Value::as_str).unwrap_or("Prompt"),
                    "open": false
                },
                "children": [
                    {"type": "ResourceRef", "props": {
                        "resourceId": resource_id,
                        "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                        "kind": "artifact",
                        "label": "History resource"
                    }},
                    {"type": "Text", "props": {
                        "text": row.get("text").cloned().unwrap_or(Value::Null)
                    }},
                    {"type": "Metric", "props": {
                        "label": "Uses",
                        "value": row.get("useCount").cloned().unwrap_or_else(|| json!(1))
                    }},
                    {"type": "Confirmation", "props": {
                        "title": "Delete entry",
                        "message": "Discard this prompt history artifact.",
                        "confirmActionId": format!("delete-history-{row_key}")
                    }}
                ]
            }));
        }
    }
    children.push(json!({
        "type": "Button",
        "props": {"label": "Refresh", "actionId": "refresh-surface"}
    }));
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
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
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        actions.extend(prompt_collection_actions(
            host, invocation, request, &functions,
        )?);
    }
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
            if let Some(inspect_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::inspect_trust")
            {
                actions.push(json!({
                    "actionId": "inspect-package-trust",
                    "label": "Inspect Trust",
                    "targetFunctionId": "module::inspect_trust",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "includeEvidence": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&inspect_trust.risk_level),
                    "approvalPolicy": {"required": inspect_trust.required_authority.approval_required},
                    "targetRevision": inspect_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(simulate_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::simulate_trust_change")
            {
                actions.push(json!({
                    "actionId": "simulate-package-trust",
                    "label": "Simulate Trust",
                    "targetFunctionId": "module::simulate_trust_change",
                    "inputSchema": trust_review_operation_input_schema(false),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "includeGeneratedUi": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&simulate_trust.risk_level),
                    "approvalPolicy": {"required": simulate_trust.required_authority.approval_required},
                    "targetRevision": simulate_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_review) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_trust_review")
            {
                actions.push(json!({
                    "actionId": "record-package-trust-review",
                    "label": "Record Review",
                    "targetFunctionId": "module::record_trust_review",
                    "inputSchema": trust_review_operation_input_schema(true),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "operatorNotes": "${input.operatorNotes}",
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_review.risk_level),
                    "approvalPolicy": {"required": record_review.required_authority.approval_required},
                    "targetRevision": record_review.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(schedule_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::schedule_trust_audit")
            {
                actions.push(json!({
                    "actionId": "schedule-package-trust-audit",
                    "label": "Schedule Audit",
                    "targetFunctionId": "module::schedule_trust_audit",
                    "inputSchema": {
                        "type": "object",
                        "required": ["scheduleId", "cadence", "timezone", "wallClockTime", "expiresAt", "reason"],
                        "additionalProperties": false,
                        "properties": {
                            "scheduleId": {"type": "string"},
                            "cadence": {"type": "string", "enum": ["daily", "weekly"]},
                            "timezone": {"type": "string"},
                            "wallClockTime": {"type": "string"},
                            "dayOfWeek": {"type": "string"},
                            "expiresAt": {"type": "string"},
                            "reason": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "scheduleId": "${input.scheduleId}",
                        "scope": "system",
                        "selectors": [manifest.get("packageId").cloned().unwrap_or_else(|| json!(resource_id))],
                        "cadence": "${input.cadence}",
                        "timezone": "${input.timezone}",
                        "wallClockTime": "${input.wallClockTime}",
                        "dayOfWeek": "${input.dayOfWeek}",
                        "expiresAt": "${input.expiresAt}",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&schedule_audit.risk_level),
                    "approvalPolicy": {"required": schedule_audit.required_authority.approval_required},
                    "targetRevision": schedule_audit.revision.0,
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
    if request.target_type == "decision" {
        let resource_id = request.target_id.clone();
        let inspection =
            host.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        let version_id = inspection
            .resource
            .current_version_id
            .clone()
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        let decision_payload = current_payload(&inspection).unwrap_or_else(|| json!({}));
        let decision_metadata = decision_payload.get("metadata").and_then(Value::as_object);
        let is_trust_root = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_root");
        let is_trust_audit_schedule = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_audit_schedule");
        for (action_id, label, target_function, input_schema, payload) in [
            (
                "inspect-trust-decision",
                "Inspect Trust",
                "module::inspect_trust",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "includeEvidence": true,
                    "limit": 50
                }),
            ),
            (
                "simulate-trust-decision",
                "Simulate",
                "module::simulate_trust_change",
                trust_review_operation_input_schema(false),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "includeGeneratedUi": true,
                    "limit": 50
                }),
            ),
            (
                "record-trust-review",
                "Record Review",
                "module::record_trust_review",
                trust_review_operation_input_schema(true),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "operatorNotes": "${input.operatorNotes}",
                    "limit": 50
                }),
            ),
            (
                "trust-audit-status",
                "Audit Status",
                "module::trust_audit_status",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "includeEvidence": true,
                    "includeQueue": true,
                    "limit": 50
                }),
            ),
            (
                "renew-trust-root",
                "Renew",
                "module::renew_trust_root",
                json!({
                    "type": "object",
                    "required": ["expiresAt", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "expiresAt": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustRootDecisionResourceId": resource_id,
                    "trustRootDecisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "expiresAt": "${input.expiresAt}",
                    "allowedPackageSelectors": decision_metadata
                        .and_then(|metadata| metadata.get("allowedPackageSelectors"))
                        .cloned()
                        .unwrap_or_else(|| json!([])),
                    "grantCeiling": decision_metadata
                        .and_then(|metadata| metadata.get("grantCeiling"))
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    "trustTierCeiling": "signed_local",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "rotate-signature-key",
                "Rotate",
                "module::rotate_signature_key",
                json!({
                    "type": "object",
                    "required": ["newTrustRootDecisionResourceId", "newTrustRootDecisionVersionId", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "newTrustRootDecisionResourceId": {"type": "string"},
                        "newTrustRootDecisionVersionId": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "oldTrustRootDecisionResourceId": resource_id,
                    "oldTrustRootDecisionVersionId": version_id,
                    "newTrustRootDecisionResourceId": "${input.newTrustRootDecisionResourceId}",
                    "newTrustRootDecisionVersionId": "${input.newTrustRootDecisionVersionId}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "expire-trust-decision",
                "Expire",
                "module::expire_trust_decision",
                json!({
                    "type": "object",
                    "required": ["reason"],
                    "additionalProperties": false,
                    "properties": {"reason": {"type": "string"}}
                }),
                json!({
                    "decisionResourceId": resource_id,
                    "decisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "${input.reason}"
                }),
            ),
            (
                "enforce-revocation",
                "Enforce",
                "module::enforce_revocation",
                json!({
                    "type": "object",
                    "required": ["mode", "activationResourceIds", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "mode": {"type": "string", "enum": ["disable", "quarantine"]},
                        "activationResourceIds": {"type": "array", "items": {"type": "string"}},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustDecisionResourceId": resource_id,
                    "expectedDecisionVersionId": version_id,
                    "mode": "${input.mode}",
                    "activationResourceIds": "${input.activationResourceIds}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "run-scheduled-trust-audit",
                "Run Audit",
                "module::run_scheduled_trust_audit",
                json!({
                    "type": "object",
                    "required": ["dueBucket"],
                    "additionalProperties": false,
                    "properties": {"dueBucket": {"type": "string"}}
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "dueBucket": "${input.dueBucket}"
                }),
            ),
            (
                "record-trust-audit-retention",
                "Review Retention",
                "module::record_trust_audit_retention",
                json!({
                    "type": "object",
                    "required": ["olderThan", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "olderThan": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "olderThan": "${input.olderThan}",
                    "reason": "${input.reason}"
                }),
            ),
        ] {
            if matches!(
                target_function,
                "module::renew_trust_root"
                    | "module::rotate_signature_key"
                    | "module::enforce_revocation"
            ) && !is_trust_root
            {
                continue;
            }
            if matches!(
                target_function,
                "module::trust_audit_status"
                    | "module::run_scheduled_trust_audit"
                    | "module::record_trust_audit_retention"
            ) && !is_trust_audit_schedule
            {
                continue;
            }
            if let Some(function) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": input_schema,
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&function.risk_level),
                    "approvalPolicy": {"required": function.required_authority.approval_required},
                    "targetRevision": function.revision.0,
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
    Ok(actions
        .into_iter()
        .map(with_stored_action_consequence)
        .collect())
}

fn prompt_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    match (request.target_id.as_str(), request.layout_profile.as_str()) {
        (PROMPT_SNIPPET_COLLECTION_TARGET, PROMPT_SNIPPET_LAYOUT_PROFILE) => {
            prompt_snippet_collection_actions(host, invocation, functions)
        }
        (PROMPT_HISTORY_COLLECTION_TARGET, PROMPT_HISTORY_LAYOUT_PROFILE) => {
            prompt_history_collection_actions(host, invocation, functions)
        }
        _ => Ok(Vec::new()),
    }
}

fn prompt_snippet_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let mut actions = Vec::new();
    actions.push(prompt_collection_action(
        invocation,
        functions,
        "create-snippet",
        "Create Snippet",
        "prompt_library::snippet_create",
        json!({
            "type": "object",
            "required": ["name", "text"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "text": {"type": "string"}
            }
        }),
        json!({
            "name": "${input.name}",
            "text": "${input.text}"
        }),
    )?);

    for row in prompt_collection_rows(host, PROMPT_SNIPPET_RESOURCE_PREFIX)? {
        let resource_id = row["resourceId"].as_str().unwrap_or_default();
        let row_key = collection_row_key(resource_id);
        let id = row["id"].as_str().unwrap_or_default();
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("update-snippet-{row_key}"),
            "Update Snippet",
            "prompt_library::snippet_update",
            json!({
                "type": "object",
                "required": [format!("name_{row_key}"), format!("text_{row_key}")],
                "additionalProperties": false,
                "properties": {
                    format!("name_{row_key}"): {"type": "string"},
                    format!("text_{row_key}"): {"type": "string"}
                }
            }),
            json!({
                "id": id,
                "name": format!("${{input.name_{row_key}}}"),
                "text": format!("${{input.text_{row_key}}}")
            }),
        )?);
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("delete-snippet-{row_key}"),
            "Delete Snippet",
            "prompt_library::snippet_delete",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({"id": id}),
        )?);
    }
    Ok(actions)
}

fn prompt_history_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let mut actions = Vec::new();
    actions.push(prompt_collection_action(
        invocation,
        functions,
        "clear-history",
        "Clear History",
        "prompt_library::history_clear",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({}),
    )?);
    for row in prompt_collection_rows(host, PROMPT_HISTORY_RESOURCE_PREFIX)? {
        let resource_id = row["resourceId"].as_str().unwrap_or_default();
        let row_key = collection_row_key(resource_id);
        let id = row["id"].as_str().unwrap_or_default();
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("delete-history-{row_key}"),
            "Delete History",
            "prompt_library::history_delete",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({"id": id}),
        )?);
    }
    Ok(actions)
}

fn prompt_collection_rows(host: &dyn PrimitiveRuntimeHost, prefix: &str) -> Result<Vec<Value>> {
    let resources = host.list_resources(ListResources {
        kind: Some("artifact".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource.resource_id.starts_with(prefix)
            && resource.lifecycle != "discarded"
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let id = payload
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| inspection.resource.resource_id.strip_prefix(prefix))
            .unwrap_or_default()
            .to_owned();
        rows.push(json!({
            "id": id,
            "resourceId": inspection.resource.resource_id,
            "sortKey": payload
                .get("updatedAt")
                .and_then(Value::as_str)
                .or_else(|| payload.get("lastUsedAt").and_then(Value::as_str))
                .or_else(|| payload.get("createdAt").and_then(Value::as_str))
                .unwrap_or_default(),
        }));
    }
    rows.sort_by(|left, right| {
        right
            .get("sortKey")
            .and_then(Value::as_str)
            .cmp(&left.get("sortKey").and_then(Value::as_str))
            .then_with(|| {
                left.get("resourceId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("resourceId").and_then(Value::as_str))
            })
    });
    rows.truncate(PROMPT_COLLECTION_LIMIT);
    Ok(rows)
}

fn prompt_collection_action(
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
    action_id: &str,
    label: &str,
    target_function: &str,
    input_schema: Value,
    payload_template: Value,
) -> Result<Value> {
    let target = functions
        .iter()
        .find(|function| function.id.as_str() == target_function)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: target_function.to_owned(),
        })?;
    Ok(json!({
        "actionId": action_id,
        "label": label,
        "targetFunctionId": target_function,
        "inputSchema": input_schema,
        "payloadTemplate": payload_template,
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&target.risk_level),
        "approvalPolicy": {"required": target.required_authority.approval_required},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    }))
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
    match optional_string(invocation.payload.get("scope"))?.as_deref() {
        None => Ok(default_resource_scope(invocation)),
        Some("system") => Ok(EngineResourceScope::System),
        Some("workspace") => {
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
        Some("session") => {
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
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "unsupported resource scope {other}"
        ))),
    }
}

fn default_resource_scope(invocation: &crate::engine::Invocation) -> EngineResourceScope {
    if let Some(session_id) = invocation.causal_context.session_id.clone() {
        return EngineResourceScope::Session(session_id);
    }
    if let Some(workspace_id) = invocation.causal_context.workspace_id.clone() {
        return EngineResourceScope::Workspace(workspace_id);
    }
    EngineResourceScope::System
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

fn risk_label(risk: &RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn trust_review_operation_input_schema(with_operator_notes: bool) -> Value {
    let mut required = vec!["operation"];
    let mut properties = json!({
        "operation": {
            "type": "string",
            "enum": super::module::TRUST_REVIEW_OPERATIONS
        }
    });
    if with_operator_notes {
        required.push("operatorNotes");
        properties["operatorNotes"] = json!({"type": "string"});
    }
    json!({
        "type": "object",
        "required": required,
        "additionalProperties": false,
        "properties": properties
    })
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
            | RESOURCE_COLLECTION_TARGET
            | "package"
            | "module_config"
            | "decision"
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

fn collection_row_key(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let hex = format!("{digest:x}");
    format!("r{}", &hex[..12])
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
                "enum": ["worker", "capability", "goal", "resource_collection", "package", "module_config", "decision", "activation", "resource", "invocation", "grant", "approval", "queue", "lease", "storage", "integrity"]
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
