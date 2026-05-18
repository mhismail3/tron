//! Generated UI primitive contracts and host-dispatched handlers.
//!
//! `ui_surface` is a resource kind. The `ui::*` capabilities are narrow
//! wrappers around the generic resource store plus the fixed component catalog.
//! They do not own durable state.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, UI_WORKER_ID, host_dispatched_registration, optional_string,
    primitive_function, required_str, required_string_owned,
};
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::ids::FunctionId;
use crate::engine::primitives::runtime::PrimitiveRuntimeHost;
use crate::engine::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion,
    EngineResourceVersionState, UI_SURFACE_KIND, UpdateResource, ui_component_catalog,
    validate_ui_surface_payload,
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
                    "validationState": {"type": "string"},
                    "bindings": {"type": "array"},
                    "actions": {"type": "array"},
                    "lineage": {"type": "object"}
                }
            }),
        ),
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
        UPDATE_SURFACE_FUNCTION => update_surface(host, invocation),
        INSPECT_SURFACE_FUNCTION => inspect_surface(host, invocation),
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
    Ok(json!({
        "inspection": inspection,
        "validationState": if payload.is_some() { "valid" } else { "missing" },
        "bindings": payload.as_ref().and_then(|payload| payload.get("bindings")).cloned().unwrap_or_else(|| json!([])),
        "actions": action_summaries(payload.as_ref()),
        "lineage": surface_lineage(inspection.as_ref()),
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
        "required": ["resource", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "resource": {"type": "object"},
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
            "version": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}
