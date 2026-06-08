//! Runtime UI surface primitive contracts and host-dispatched handlers.
//!
//! `ui_surface` is a resource kind. The `ui::*` functions are narrow wrappers
//! around the generic resource store: create, update, inspect, validate,
//! expire, discard, and record action submissions. They do not author target
//! projections, route actions to functions, or own product workflow state.

mod schemas;
mod validation;

use schemas::*;
use validation::{current_version_hash, submit_action, surface_validation_state, validate_surface};

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, UI_WORKER_ID, host_dispatched_registration, optional_string,
    primitive_function, required_str, required_string_owned,
};
use crate::engine::durability::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion,
    EngineResourceVersionState, UI_SURFACE_KIND, UpdateResource, validate_ui_surface_payload,
};
use crate::engine::kernel::types::{
    CompensationKind, DurableOutputContract, EffectClass, FunctionDefinition, IdempotencyContract,
    ResourceLeaseRequirement, VisibilityScope,
};
use crate::engine::primitives::runtime::PrimitiveRuntimeHost;
use crate::engine::{EngineError, EngineResourceScope, Result, WorkerId};

pub(crate) const CREATE_SURFACE_FUNCTION: &str = "ui::create_surface";
pub(crate) const UPDATE_SURFACE_FUNCTION: &str = "ui::update_surface";
pub(crate) const INSPECT_SURFACE_FUNCTION: &str = "ui::inspect_surface";
pub(crate) const DISCARD_SURFACE_FUNCTION: &str = "ui::discard_surface";
pub(crate) const SUBMIT_ACTION_FUNCTION: &str = "ui::submit_action";
pub(crate) const VALIDATE_SURFACE_FUNCTION: &str = "ui::validate_surface";
pub(crate) const EXPIRE_SURFACE_FUNCTION: &str = "ui::expire_surface";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        ui_write(
            CREATE_SURFACE_FUNCTION,
            "validate and create a runtime ui_surface resource",
            create_surface_schema(),
            surface_resource_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_write(
            UPDATE_SURFACE_FUNCTION,
            "compare-and-set update a runtime ui_surface resource",
            update_surface_schema(),
            surface_version_response_schema(),
        )
        .with_output_contract(DurableOutputContract::resource_backed([UI_SURFACE_KIND])),
        ui_read(
            INSPECT_SURFACE_FUNCTION,
            "inspect a runtime ui_surface resource",
            json!({
                "type": "object",
                "required": ["surfaceResourceId"],
                "additionalProperties": false,
                "properties": {"surfaceResourceId": {"type": "string"}}
            }),
            json!({
                "type": "object",
                "required": ["inspection", "validationState", "actions", "lineage"],
                "additionalProperties": false,
                "properties": {
                    "inspection": {"type": ["object", "null"]},
                    "surface": {"type": ["object", "null"]},
                    "resourceRef": {"type": ["object", "null"]},
                    "validationState": {"type": "string"},
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
            "record a stored runtime UI action submission",
            submit_action_schema(),
            submit_action_response_schema(),
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
        CREATE_SURFACE_FUNCTION => create_surface(host, invocation),
        UPDATE_SURFACE_FUNCTION => update_surface(host, invocation),
        INSPECT_SURFACE_FUNCTION => inspect_surface(host, invocation),
        VALIDATE_SURFACE_FUNCTION => validate_surface(host, invocation),
        EXPIRE_SURFACE_FUNCTION => expire_surface(host, invocation),
        DISCARD_SURFACE_FUNCTION => discard_surface(host, invocation),
        SUBMIT_ACTION_FUNCTION => submit_action(host, invocation),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

fn create_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface = normalized_surface_payload(invocation)?;
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

fn update_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface = normalized_surface_payload(invocation)?;
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
        "actions": action_summaries(payload.as_ref()),
        "lineage": surface_lineage(inspection.as_ref()),
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

fn normalized_surface_payload(invocation: &crate::engine::Invocation) -> Result<Value> {
    let surface = invocation.payload.get("surface").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{} requires surface", invocation.function_id))
    })?;
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
                    "expiresAt": action.get("expiresAt").cloned().unwrap_or(Value::Null),
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
