//! Control-plane primitive contracts and projections.
//!
//! The control worker is a projection surface over existing substrate truth.
//! It owns no durable state and exposes no mutation multiplexer.

use chrono::{DateTime, Utc};
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
    ACTIVATION_RECORD_KIND, EngineResource, EngineResourceInspection, ListResources,
    MODULE_CONFIG_KIND, UI_SURFACE_KIND, WORKER_PACKAGE_KIND,
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
                "required": ["catalogRevision", "workers", "capabilities", "resourceTypes", "activeGoals", "modulePackages", "moduleConfigs", "activationRecords", "moduleHealth", "moduleSourceTrust", "invocations", "grants", "queues", "leases", "approvals", "storage", "integrityWarnings", "availableActions", "uiSurfaceRefs"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "workers": {"type": "array"},
                    "capabilities": {"type": "array"},
                    "resourceTypes": {"type": "array"},
                    "activeGoals": {"type": "array"},
                    "modulePackages": {"type": "array"},
                    "moduleConfigs": {"type": "array"},
                    "activationRecords": {"type": "array"},
                    "moduleHealth": {"type": "array"},
                    "moduleSourceTrust": {"type": "array"},
                    "invocations": {"type": "array"},
                    "grants": {"type": "array"},
                    "queues": {"type": "array"},
                    "leases": {"type": "array"},
                    "approvals": {"type": "array"},
                    "storage": {"type": ["object", "null"]},
                    "integrityWarnings": {"type": "array"},
                    "availableActions": {"type": "array"},
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
                "required": ["targetType", "targetId", "graph", "availableActions", "uiSurfaceRefs"],
                "additionalProperties": false,
                "properties": {
                    "targetType": {"type": "string"},
                    "targetId": {"type": "string"},
                    "graph": {"type": "object"},
                    "availableActions": {"type": "array"},
                    "uiSurfaceRefs": {"type": "array"}
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
                "enum": ["worker", "capability", "grant", "goal", "package", "module_config", "activation", "resource", "invocation", "trace", "approval", "queue", "lease", "storage", "integrity"]
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
    let module_packages = host.list_resources(ListResources {
        kind: Some(WORKER_PACKAGE_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit,
    })?;
    let module_configs = host.list_resources(ListResources {
        kind: Some(MODULE_CONFIG_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit,
    })?;
    let activation_records = host.list_resources(ListResources {
        kind: Some(ACTIVATION_RECORD_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit,
    })?;
    let module_health = activation_records
        .iter()
        .filter_map(|resource| activation_health_summary(host, resource).transpose())
        .collect::<Result<Vec<_>>>()?;
    let module_source_trust = module_packages
        .iter()
        .filter_map(|resource| module_source_trust_summary(host, resource).transpose())
        .collect::<Result<Vec<_>>>()?;
    let invocations = latest_invocations(host.invocations(), limit)
        .iter()
        .map(|record| invocation_record_value(record, false))
        .collect::<Vec<_>>();
    let grants = host.list_grants(ListGrants {
        parent_grant_id: None,
        lifecycle: Some(EngineGrantLifecycle::Active),
        limit,
    })?;
    let approvals =
        host.approval_records(None, invocation.causal_context.session_id.as_deref(), limit)?;
    let queues = host.queue_items("engine", limit).unwrap_or_default();
    let storage = host.storage_stats().ok().map(|stats| json!(stats));
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "workers": host.visible_workers(&actor),
        "capabilities": capabilities,
        "resourceTypes": host.resource_type_definitions()?,
        "activeGoals": active_goals,
        "modulePackages": module_packages,
        "moduleConfigs": module_configs,
        "activationRecords": activation_records,
        "moduleHealth": module_health,
        "moduleSourceTrust": module_source_trust,
        "invocations": invocations,
        "grants": grants,
        "queues": queues,
        "leases": [],
        "approvals": approvals,
        "storage": storage,
        "integrityWarnings": substrate_integrity_warnings(host)?,
        "availableActions": substrate_actions(),
        "uiSurfaceRefs": ui_surface_refs(host, limit)?,
    }))
}

fn module_source_trust_summary(
    host: &dyn PrimitiveRuntimeHost,
    resource: &EngineResource,
) -> Result<Option<Value>> {
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let Some(payload) = current_payload(&inspection) else {
        return Ok(None);
    };
    let package_digest = payload.get("packageDigest").and_then(Value::as_str);
    let source_approval_refs = source_approval_refs(
        host,
        &resource.resource_id,
        resource.current_version_id.as_deref(),
        package_digest,
    )?;
    let approval_warnings = source_approval_refs
        .iter()
        .filter_map(source_approval_warning)
        .collect::<Vec<_>>();
    Ok(Some(json!({
        "packageResourceId": resource.resource_id,
        "packageVersionId": resource.current_version_id,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "sourceTrustStatus": payload.get("sourceTrustStatus").cloned().unwrap_or(Value::Null),
        "effectiveTrustTier": payload.get("effectiveTrustTier").cloned().unwrap_or(Value::Null),
        "sourceEvidenceRefs": payload.get("sourceEvidenceRefs").cloned().unwrap_or_else(|| json!([])),
        "sourceApprovalRefs": source_approval_refs,
        "approvalWarnings": approval_warnings,
        "conformanceEvidenceRefs": payload.get("conformanceEvidenceRefs").cloned().unwrap_or_else(|| json!([])),
        "policyDiagnostics": payload.get("policyDiagnostics").cloned().unwrap_or_else(|| json!({})),
    })))
}

fn source_approval_refs(
    host: &dyn PrimitiveRuntimeHost,
    package_resource_id: &str,
    package_version_id: Option<&str>,
    package_digest: Option<&str>,
) -> Result<Vec<Value>> {
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 500,
    })?;
    decisions
        .into_iter()
        .filter_map(|resource| {
            source_approval_ref_for_decision(
                host,
                resource,
                package_resource_id,
                package_version_id,
                package_digest,
            )
            .transpose()
        })
        .collect()
}

fn source_approval_ref_for_decision(
    host: &dyn PrimitiveRuntimeHost,
    resource: EngineResource,
    package_resource_id: &str,
    package_version_id: Option<&str>,
    package_digest: Option<&str>,
) -> Result<Option<Value>> {
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let Some(payload) = current_payload(&inspection) else {
        return Ok(None);
    };
    let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
        return Ok(None);
    };
    let target_matches = metadata.get("decisionType").and_then(Value::as_str)
        == Some("module_source_approval")
        && metadata.get("packageResourceId").and_then(Value::as_str) == Some(package_resource_id)
        && package_version_id.is_none_or(|version_id| {
            metadata.get("packageVersionId").and_then(Value::as_str) == Some(version_id)
        })
        && package_digest.is_none_or(|digest| {
            metadata.get("packageDigest").and_then(Value::as_str) == Some(digest)
        });
    if !target_matches {
        return Ok(None);
    }
    Ok(Some(json!({
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "lifecycle": resource.lifecycle,
        "scope": metadata.get("scope").cloned().unwrap_or(Value::Null),
        "expiresAt": metadata.get("expiresAt").cloned().unwrap_or(Value::Null),
        "relation": "source_approval",
    })))
}

fn source_approval_warning(reference: &Value) -> Option<Value> {
    let status = reference.get("status").and_then(Value::as_str);
    let lifecycle = reference.get("lifecycle").and_then(Value::as_str);
    if status == Some("revoked") || lifecycle == Some("archived") {
        return Some(json!({
            "code": "source_approval_revoked",
            "decisionResourceId": reference.get("resourceId").cloned().unwrap_or(Value::Null),
        }));
    }
    let expires_at = reference
        .get("expiresAt")
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc));
    if expires_at.is_some_and(|value| value <= Utc::now()) {
        return Some(json!({
            "code": "source_approval_expired",
            "decisionResourceId": reference.get("resourceId").cloned().unwrap_or(Value::Null),
        }));
    }
    None
}

fn activation_health_summary(
    host: &dyn PrimitiveRuntimeHost,
    resource: &EngineResource,
) -> Result<Option<Value>> {
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let Some(payload) = current_payload(&inspection) else {
        return Ok(None);
    };
    Ok(Some(json!({
        "activationResourceId": resource.resource_id,
        "activationVersionId": resource.current_version_id,
        "activationStatus": payload.get("activationStatus").cloned().unwrap_or(Value::Null),
        "healthResult": payload.get("healthResult").cloned().unwrap_or(Value::Null),
        "healthEvidenceRef": payload.get("healthEvidenceRef").cloned().unwrap_or(Value::Null),
        "integrityDiagnostics": payload.get("integrityDiagnostics").cloned().unwrap_or(Value::Null),
        "recovery": payload.get("recovery").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
        "derivedGrantId": payload.get("derivedGrantId").cloned().unwrap_or(Value::Null),
    })))
}

fn current_payload(inspection: &EngineResourceInspection) -> Option<&Value> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| &version.payload)
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
        "package" => {
            let resource_id = if target_id.starts_with("worker-package:") {
                target_id.to_owned()
            } else {
                format!("worker-package:{target_id}")
            };
            json!({ "package": host.inspect_resource(&resource_id)? })
        }
        "module_config" => {
            json!({ "moduleConfig": host.inspect_resource(target_id)? })
        }
        "activation" => {
            let resource_id = if target_id.starts_with("activation:") {
                target_id.to_owned()
            } else {
                format!("activation:{target_id}")
            };
            json!({ "activation": host.inspect_resource(&resource_id)? })
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
                "approvals": trace.approvals,
                "leases": trace.leases,
                "compensation": trace.compensation,
            })
        }
        "approval" => {
            let approval = host
                .approval_records(None, invocation.causal_context.session_id.as_deref(), 500)?
                .into_iter()
                .find(|record| record.approval_id == target_id);
            json!({ "approval": approval })
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
        "availableActions": actions_for_target(target_type, target_id),
        "uiSurfaceRefs": ui_surface_refs_for_target(host, target_type, target_id)?,
    }))
}

fn ui_surface_refs(host: &dyn PrimitiveRuntimeHost, limit: usize) -> Result<Vec<Value>> {
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

fn ui_surface_refs_for_target(
    host: &dyn PrimitiveRuntimeHost,
    target_type: &str,
    target_id: &str,
) -> Result<Vec<Value>> {
    let functions = host.discover_functions(&FunctionQuery {
        include_internal: true,
        ..FunctionQuery::default()
    });
    Ok(ui_surface_refs(host, 100)?
        .into_iter()
        .filter(|surface| {
            let bound_to_target = surface_targets(surface).iter().any(|target| {
                target.get("targetType").and_then(Value::as_str) == Some(target_type)
                    && target.get("targetId").and_then(Value::as_str) == Some(target_id)
            });
            let action_targets_capability = target_type == "capability"
                && surface_actions(surface).iter().any(|action| {
                    action.get("targetFunctionId").and_then(Value::as_str) == Some(target_id)
                });
            let action_targets_worker = target_type == "worker"
                && surface_actions(surface).iter().any(|action| {
                    let Some(function_id) = action.get("targetFunctionId").and_then(Value::as_str)
                    else {
                        return false;
                    };
                    functions.iter().any(|function| {
                        function.id.as_str() == function_id
                            && function.owner_worker.as_str() == target_id
                    })
                });
            bound_to_target || action_targets_capability || action_targets_worker
        })
        .collect())
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
        "catalog": payload.get("catalog").cloned().unwrap_or(Value::Null),
        "expiresAt": payload.get("expiresAt").cloned().unwrap_or(Value::Null),
        "targets": payload.get("bindings").cloned().unwrap_or_else(|| json!([])),
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

fn surface_targets(surface: &Value) -> Vec<Value> {
    surface
        .get("targets")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn surface_actions(surface: &Value) -> Vec<Value> {
    surface
        .get("actions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
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
                    "targetFunctionId": action.get("targetFunctionId").cloned().unwrap_or(Value::Null),
                    "requiredGrant": action.get("requiredGrant").cloned().unwrap_or(Value::Null),
                    "requiredRisk": action.get("requiredRisk").cloned().unwrap_or(Value::Null),
                    "targetRevision": action.get("targetRevision").cloned().unwrap_or(Value::Null),
                    "expiresAt": action.get("expiresAt").cloned().unwrap_or(Value::Null),
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

fn substrate_actions() -> Vec<Value> {
    vec![
        action_summary("ui::surface_for_target", "*", "targetId", "medium", false),
        action_summary(
            "ui::refresh_surface",
            "*",
            "surfaceResourceId",
            "medium",
            false,
        ),
        action_summary("grant::revoke", "grant", "grantId", "high", true),
        action_summary("worker::disconnect", "worker", "workerId", "high", true),
        action_summary(
            "resource::link",
            "resource",
            "sourceResourceId",
            "medium",
            false,
        ),
        action_summary(
            "artifact::promote",
            "resource",
            "resourceId",
            "medium",
            false,
        ),
        action_summary(
            "approval::resolve",
            "approval",
            "approvalId",
            "medium",
            false,
        ),
        action_summary("agent::abort", "goal", "sessionId", "high", true),
        action_summary(
            "module::inspect_package",
            "package",
            "packageId",
            "low",
            false,
        ),
        action_summary(
            "module::configure",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::activate",
            "package",
            "packageResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::disable",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::upgrade",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::rollback",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::quarantine",
            "activation",
            "resourceId",
            "high",
            true,
        ),
        action_summary(
            "module::check_health",
            "activation",
            "activationResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::verify_integrity",
            "activation",
            "resourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::recover_activation",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::verify_source",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::approve_source",
            "package",
            "packageResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::revoke_source_approval",
            "package",
            "decisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::policy_decide",
            "package",
            "packageResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::run_conformance",
            "package",
            "resourceId",
            "medium",
            false,
        ),
    ]
}

fn actions_for_target(target_type: &str, target_id: &str) -> Vec<Value> {
    substrate_actions()
        .into_iter()
        .filter(|action| {
            action
                .get("targetType")
                .and_then(Value::as_str)
                .is_none_or(|kind| {
                    kind == "*"
                        || kind == target_type
                        || target_type == "goal" && kind == "resource"
                })
        })
        .map(|mut action| {
            let key = match target_type {
                "worker" => "workerId",
                "grant" => "grantId",
                "package" => "packageId",
                "activation" => "activationResourceId",
                "goal" | "resource" => "resourceId",
                _ => "targetId",
            };
            action["target"] = json!({
                "field": key,
                "value": target_id,
            });
            action
        })
        .collect()
}

fn action_summary(
    function_id: &str,
    target_type: &str,
    target_field: &str,
    risk: &str,
    approval_required: bool,
) -> Value {
    json!({
        "functionId": function_id,
        "targetType": target_type,
        "targetField": target_field,
        "requiredRisk": risk,
        "approvalRequired": approval_required,
        "targetRevision": Value::Null,
    })
}
