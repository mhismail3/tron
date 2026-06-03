//! Generated UI primitive contracts and host-dispatched handlers.
//!
//! `ui_surface` is a resource kind. The `ui::*` capabilities are narrow
//! wrappers around the generic resource store plus the fixed component catalog.
//! They do not own durable state. Generated surface authoring lives in
//! `ui/authoring/` so fixed clients can render server-owned review surfaces
//! without constructing target functions, payload templates, grants, or
//! stale-state policy locally. The authoring folder is split by target family:
//! prompt-library collections, notifications, subagent lineage, source-control,
//! AgentControl, capability actions, and module package/activation/decision
//! operator surfaces. Capability authoring can expose a stored invoke action
//! for session-created functions when the required request fields map to the
//! fixed native catalog. Resource-collection authoring uses bounded projections
//! over `PrimitiveRuntimeHost::list_resources` and `inspect_resource`.
//! Generated UI writes and action submissions share a `ui_surface` lifecycle
//! lease and compensation notes so server-authored surfaces and stored action
//! submissions are visible in the invocation, lease, and compensation ledgers.

mod authoring;
mod schemas;
mod validation;

use authoring::{AuthoredSurface, SurfaceAuthoringRequest, author_surface_for_target};
use schemas::*;
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
    CompensationKind, DurableOutputContract, EffectClass, FunctionDefinition, IdempotencyContract,
    ResourceLeaseRequirement, RiskLevel, VisibilityScope,
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
const SOURCE_CONTROL_TARGET: &str = "source_control";
const AGENT_CONTROL_TARGET: &str = "agent_control";
const SOURCE_CONTROL_SESSION_LAYOUT_PROFILE: &str = "source_control.session.v1";
const AGENT_CONTROL_SESSION_LAYOUT_PROFILE: &str = "agent_control.session.v1";
const PROMPT_SNIPPET_COLLECTION_TARGET: &str = "artifact:prompt-snippet";
const PROMPT_HISTORY_COLLECTION_TARGET: &str = "artifact:prompt-history";
const PROMPT_SNIPPET_RESOURCE_PREFIX: &str = "artifact:prompt-snippet:";
const PROMPT_HISTORY_RESOURCE_PREFIX: &str = "artifact:prompt-history:";
const PROMPT_SNIPPET_LAYOUT_PROFILE: &str = "prompt_library.snippets.v1";
const PROMPT_HISTORY_LAYOUT_PROFILE: &str = "prompt_library.history.v1";
const PROMPT_COLLECTION_LIMIT: usize = 25;
const RESOURCE_COLLECTION_SCAN_LIMIT: usize = 500;
const NOTIFICATION_COLLECTION_TARGET: &str = "notification";
const NOTIFICATION_RESOURCE_PREFIX: &str = "notification:";
const NOTIFICATION_INBOX_LAYOUT_PROFILE: &str = "notifications.inbox.v1";
const NOTIFICATION_COLLECTION_LIMIT: usize = 50;
const SUBAGENT_COLLECTION_TARGET: &str = "agent_result:subagent";
const SUBAGENT_RESULT_RESOURCE_PREFIX: &str = "agent_result:subagent:";
const SUBAGENT_LINEAGE_LAYOUT_PROFILE: &str = "subagent.lineage.v1";
const SUBAGENT_COLLECTION_LIMIT: usize = 50;
const SOURCE_CONTROL_INVOCATION_LIMIT: usize = 12;
const SOURCE_CONTROL_FILE_LIMIT: usize = 25;

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
    .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
        UI_SURFACE_KIND,
        "ui_surface:lifecycle",
        300000,
    ))
    .with_compensation(super::primitive_compensation(
        CompensationKind::ManualOnly,
        "generated UI surface writes and action submissions retain server-owned resource versions and canonical child invocation records for manual recovery",
    ))
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
            | SOURCE_CONTROL_TARGET
            | AGENT_CONTROL_TARGET
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
                    "consequence": action.get("consequence").cloned().unwrap_or(Value::Null),
                    "presentation": action.get("presentation").cloned().unwrap_or(Value::Null),
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
