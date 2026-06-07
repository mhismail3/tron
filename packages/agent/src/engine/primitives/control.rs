//! Control-plane primitive contracts and projections.
//!
//! The control worker is a projection surface over existing substrate truth.
//! It owns no durable state and exposes no mutation multiplexer.

use serde_json::{Value, json};

use super::runtime::{
    PrimitiveRuntimeHost, actor_context, invocation_record_value, optional_u64, required_str,
    trace_components, trace_summary,
};
use super::{
    CONTROL_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration,
    primitive_function,
};
use crate::engine::discovery::FunctionQuery;
use crate::engine::grants::{EngineGrantLifecycle, ListGrants};
use crate::engine::resources::{
    EngineResource, EngineResourceInspection, ListResources, UI_SURFACE_KIND,
};
use crate::engine::{EffectClass, EngineError, Invocation, Result, VisibilityScope, WorkerId};

pub(crate) const SNAPSHOT_FUNCTION: &str = "control::snapshot";
pub(crate) const INSPECT_FUNCTION: &str = "control::inspect";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        control_read(
            SNAPSHOT_FUNCTION,
            "project the current worker/capability/resource/grant/invocation substrate",
            snapshot_schema(),
            json!({
                "type": "object",
                "required": ["catalogRevision", "workers", "capabilities", "resourceTypes", "activeGoals", "invocations", "grants", "queues", "leases", "storage", "integrityWarnings", "uiSurfaceRefs"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "workers": {"type": "array"},
                    "capabilities": {"type": "array"},
                    "resourceTypes": {"type": "array"},
                    "activeGoals": {"type": "array"},
                    "invocations": {"type": "array"},
                    "grants": {"type": "array"},
                    "queues": {"type": "array"},
                    "leases": {"type": "array"},
                    "storage": {"type": ["object", "null"]},
                    "integrityWarnings": {"type": "array"},
                    "uiSurfaceRefs": {"type": "array"}
                }
            }),
        ),
        control_read(
            INSPECT_FUNCTION,
            "inspect one substrate target graph",
            inspect_schema(),
            json!({
                "type": "object",
                "required": ["targetType", "targetId", "graph"],
                "additionalProperties": false,
                "properties": {
                    "targetType": {"type": "string"},
                    "targetId": {"type": "string"},
                    "graph": {"type": "object"}
                }
            }),
        ),
    ])
}

fn control_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> PrimitiveFunctionRegistration {
    let mut definition = primitive_function(
        id,
        CONTROL_WORKER_ID,
        description,
        EffectClass::PureRead,
        "control.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    host_dispatched_registration(definition)
}

fn snapshot_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "limit": {"type": "integer"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn inspect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {
                "type": "string",
                "enum": ["worker", "capability", "grant", "goal", "resource", "invocation", "trace", "queue", "lease", "storage", "integrity"]
            },
            "targetId": {"type": "string"},
            "includeFullPayloads": {"type": "boolean"}
        }
    })
}

pub(in crate::engine) fn dispatch(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    match invocation.function_id.as_str() {
        SNAPSHOT_FUNCTION => control_snapshot(host, invocation),
        INSPECT_FUNCTION => control_inspect(host, invocation),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

fn control_snapshot(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let actor = actor_context(&invocation.causal_context);
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let limit = limit.clamp(1, 500);
    let capabilities = host.discover_functions(&FunctionQuery {
        actor: Some(actor.clone()),
        include_internal: false,
        ..FunctionQuery::default()
    });
    let active_goals = host
        .list_resources(ListResources {
            kind: Some("goal".to_owned()),
            scope: None,
            lifecycle: None,
            limit,
        })?
        .into_iter()
        .filter(|resource| !matches!(resource.lifecycle.as_str(), "completed" | "archived"))
        .collect::<Vec<_>>();
    let invocations = latest_invocations(host.invocations(), limit)
        .iter()
        .map(|record| invocation_record_value(record, false))
        .collect::<Vec<_>>();
    let grants = host.list_grants(ListGrants {
        parent_grant_id: None,
        lifecycle: Some(EngineGrantLifecycle::Active),
        limit,
    })?;
    let queues = host.queue_items("engine", limit).unwrap_or_default();
    let storage = host.storage_stats().ok().map(|stats| json!(stats));
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "workers": host.visible_workers(&actor),
        "capabilities": capabilities,
        "resourceTypes": host.resource_type_definitions()?,
        "activeGoals": active_goals,
        "invocations": invocations,
        "grants": grants,
        "queues": queues,
        "leases": [],
        "storage": storage,
        "integrityWarnings": substrate_integrity_warnings(host)?,
        "uiSurfaceRefs": ui_surface_refs(host, limit)?,
    }))
}

fn control_inspect(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let target_type = required_str(&invocation.payload, "targetType")?;
    let target_id = required_str(&invocation.payload, "targetId")?;
    let include_full_payloads = invocation
        .payload
        .get("includeFullPayloads")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let graph = match target_type {
        "worker" => {
            let id = WorkerId::new(target_id.to_owned())?;
            let functions = host
                .discover_functions(&FunctionQuery {
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .filter(|function| function.owner_worker == id)
                .collect::<Vec<_>>();
            json!({
                "worker": host.inspect_worker(&id)?,
                "capabilities": functions,
            })
        }
        "capability" => {
            let function = host
                .discover_functions(&FunctionQuery {
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .find(|function| function.id.as_str() == target_id);
            json!({ "capability": function })
        }
        "grant" => {
            let grant_id = crate::engine::ids::AuthorityGrantId::new(target_id.to_owned())?;
            json!({ "grant": host.inspect_grant(&grant_id)? })
        }
        "goal" | "resource" => {
            json!({ "resource": host.inspect_resource(target_id)? })
        }
        "invocation" => {
            let invocation = host
                .invocations()
                .into_iter()
                .find(|record| record.invocation_id.as_str() == target_id);
            json!({ "invocation": invocation.as_ref().map(|record| invocation_record_value(record, include_full_payloads)) })
        }
        "trace" => {
            let trace = trace_components(host, target_id)?;
            json!({
                "summary": trace_summary(target_id, &trace),
                "invocations": trace.invocations.iter().map(|record| invocation_record_value(record, include_full_payloads)).collect::<Vec<_>>(),
                "streams": trace.streams,
                "leases": trace.leases,
                "compensation": trace.compensation,
            })
        }
        "queue" => {
            let item = host
                .queue_items("engine", 500)
                .unwrap_or_default()
                .into_iter()
                .find(|item| item.receipt_id == target_id || item.queue == target_id);
            json!({ "queue": item })
        }
        "lease" => {
            json!({ "lease": host.resource_lease(target_id)? })
        }
        "storage" => {
            json!({ "storage": host.storage_stats().ok().map(|stats| json!(stats)) })
        }
        "integrity" => {
            json!({ "warnings": substrate_integrity_warnings(host)? })
        }
        _ => {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported control target type {target_type}"
            )));
        }
    };
    Ok(json!({
        "targetType": target_type,
        "targetId": target_id,
        "graph": graph,
    }))
}

fn ui_surface_refs(host: &dyn PrimitiveRuntimeHost, limit: usize) -> Result<Vec<Value>> {
    let limit = limit.clamp(1, 500);
    host.list_resources(ListResources {
        kind: Some(UI_SURFACE_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit,
    })?
    .into_iter()
    .filter_map(|resource| ui_surface_ref_for_resource(host, resource).transpose())
    .collect()
}

fn ui_surface_ref_for_resource(
    host: &dyn PrimitiveRuntimeHost,
    resource: EngineResource,
) -> Result<Option<Value>> {
    if matches!(
        resource.lifecycle.as_str(),
        "discarded" | "damaged" | "expired"
    ) {
        return Ok(None);
    }
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let payload = current_resource_payload(&inspection).unwrap_or(Value::Null);
    Ok(Some(json!({
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "kind": resource.kind,
        "lifecycle": resource.lifecycle,
        "surfaceId": payload.get("surfaceId").cloned().unwrap_or(Value::Null),
        "title": payload.get("title").cloned().unwrap_or(Value::Null),
        "purpose": payload.get("purpose").cloned().unwrap_or(Value::Null),
        "schemaVersion": payload.get("schemaVersion").cloned().unwrap_or(Value::Null),
        "expiresAt": payload.get("expiresAt").cloned().unwrap_or(Value::Null),
        "actions": ui_surface_action_summaries(&payload),
    })))
}

fn current_resource_payload(inspection: &EngineResourceInspection) -> Option<Value> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| version.payload.clone())
}

fn ui_surface_action_summaries(payload: &Value) -> Value {
    let Some(actions) = payload.get("actions").and_then(Value::as_array) else {
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

fn latest_invocations(
    mut invocations: Vec<crate::engine::InvocationRecord>,
    limit: usize,
) -> Vec<crate::engine::InvocationRecord> {
    invocations.sort_by_key(|record| record.timestamp);
    invocations.reverse();
    invocations.truncate(limit);
    invocations
}

fn substrate_integrity_warnings(host: &dyn PrimitiveRuntimeHost) -> Result<Vec<Value>> {
    let damaged = host
        .list_resources(ListResources {
            kind: None,
            scope: None,
            lifecycle: Some("damaged".to_owned()),
            limit: 50,
        })?
        .into_iter()
        .map(|resource| {
            json!({
                "kind": "damaged_resource",
                "resourceId": resource.resource_id,
                "resourceKind": resource.kind,
            })
        })
        .collect();
    Ok(damaged)
}
