//! Privileged primitive query runtime.
//!
//! Catalog, worker, and observability primitives need access to host-owned
//! catalog and ledger state. The response contracts live here so `EngineHost`
//! stays a coordinator rather than a primitive response bucket.

use serde_json::{Value, json};

use super::{catalog, observability, worker};
use crate::engine::approval::EngineApprovalRecord;
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::{InvocationId, TriggerId, WorkerId};
use crate::engine::invocation::{CausalContext, Invocation, InvocationRecord};
use crate::engine::leases::EngineResourceLease;
use crate::engine::streams::EngineStreamEvent;
use crate::engine::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition,
};

/// Narrow host interface required by host-dispatched primitive workers.
pub(in crate::engine) trait PrimitiveRuntimeHost {
    fn catalog_revision(&self) -> CatalogRevision;
    fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition>;
    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition>;
    fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition>;
    fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition>;
    fn inspect_catalog_item(&self, invocation: &Invocation) -> Result<Value>;
    fn watch_catalog_snapshot_base(&self, invocation: &Invocation) -> Result<Value>;
    fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition>;
    fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool>;
    fn unregister_worker(&mut self, id: &WorkerId, owner_actor: &str) -> Result<()>;
    fn invocations(&self) -> Vec<InvocationRecord>;
    fn ledger_catalog_changes(&self) -> Result<Vec<CatalogChange>>;
    fn approval_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineApprovalRecord>>;
    fn stream_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineStreamEvent>>;
    fn resource_leases_for_trace(&self, trace_id: &str) -> Result<Vec<EngineResourceLease>>;
    fn compensation_records_for_trace(&self, trace_id: &str) -> Result<Vec<Value>>;
    fn worker_count(&self) -> usize;
    fn function_count(&self) -> usize;
    fn trigger_count(&self) -> usize;
    fn trigger_type_count(&self) -> usize;
    fn invocation_count(&self) -> usize;
    fn catalog_change_count(&self) -> usize;
}

pub(in crate::engine) fn dispatch(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    match invocation.function_id.as_str() {
        catalog::LIST_FUNCTION => catalog_list(host, invocation),
        catalog::INSPECT_FUNCTION => host.inspect_catalog_item(invocation),
        catalog::WATCH_SNAPSHOT_FUNCTION => catalog_watch_snapshot(host, invocation),
        worker::LIST_FUNCTION => worker_list(host, invocation),
        worker::GET_FUNCTION => worker_get(host, invocation),
        worker::HEALTH_FUNCTION => worker_health(host, invocation),
        worker::DISCONNECT_FUNCTION => worker_disconnect(host, invocation),
        observability::TRACE_GET_FUNCTION => trace_get(host, invocation),
        observability::TRACE_LIST_FUNCTION => trace_list(host, invocation),
        observability::SPAN_LIST_FUNCTION => span_list(host, invocation),
        observability::LOG_QUERY_FUNCTION => log_query(host, invocation),
        observability::METRICS_SNAPSHOT_FUNCTION => metrics_snapshot(host),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

fn catalog_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let actor = actor_context(&invocation.causal_context);
    let query = FunctionQuery {
        actor: Some(actor.clone()),
        visibility: optional_visibility(invocation.payload.get("visibility"))?,
        namespace_prefix: optional_string(invocation.payload.get("namespacePrefix"))?,
        text: None,
        effect_class: None,
        max_risk: None,
        health: None,
        include_internal: invocation
            .payload
            .get("includeInternal")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    };
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "functions": host.discover_functions(&query),
        "workers": host.visible_workers(&actor),
        "triggers": host.visible_triggers(&actor),
        "triggerTypes": host.visible_trigger_types(&actor),
    }))
}

fn catalog_watch_snapshot(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let response = host.watch_catalog_snapshot_base(invocation)?;
    let actor = actor_context(&invocation.causal_context);
    let query = FunctionQuery {
        actor: Some(actor.clone()),
        visibility: None,
        namespace_prefix: None,
        text: None,
        effect_class: None,
        max_risk: None,
        health: None,
        include_internal: false,
    };
    Ok(json!({
        "changes": response.get("changes").cloned().unwrap_or_else(|| json!([])),
        "snapshot": {
            "functions": host.discover_functions(&query),
            "workers": host.visible_workers(&actor),
            "triggers": host.visible_triggers(&actor),
            "triggerTypes": host.visible_trigger_types(&actor),
        },
        "currentRevision": response.get("currentRevision").cloned().unwrap_or(Value::Null),
        "nextRevision": response.get("nextRevision").cloned().unwrap_or(Value::Null),
        "hasMore": response.get("hasMore").cloned().unwrap_or(Value::Bool(false)),
    }))
}

fn worker_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let actor = actor_context(&invocation.causal_context);
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "workers": host.visible_workers(&actor),
    }))
}

fn worker_get(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    let actor = actor_context(&invocation.causal_context);
    let worker = host.inspect_worker(&id)?;
    if !is_visibility_visible(
        &worker.visibility,
        worker.provenance.session_id.as_deref(),
        worker.provenance.workspace_id.as_deref(),
        &actor,
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "worker {id} is not visible"
        )));
    }
    Ok(json!({ "worker": worker }))
}

fn worker_health(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    let actor = actor_context(&invocation.causal_context);
    let worker = host.inspect_worker(&id)?;
    let functions = host
        .discover_functions(&FunctionQuery {
            actor: Some(actor),
            visibility: None,
            namespace_prefix: None,
            text: None,
            effect_class: None,
            max_risk: None,
            health: None,
            include_internal: true,
        })
        .into_iter()
        .filter(|function| function.owner_worker == id)
        .collect::<Vec<_>>();
    let triggers = host
        .visible_triggers(&actor_context(&invocation.causal_context))
        .into_iter()
        .filter(|trigger| trigger.owner_worker == id)
        .collect::<Vec<_>>();
    let health = if functions
        .iter()
        .any(|function| !function.health.is_routable())
    {
        "unhealthy"
    } else {
        "healthy"
    };
    Ok(json!({
        "worker": worker,
        "functions": functions,
        "triggers": triggers,
        "health": health,
    }))
}

fn worker_disconnect(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    if host.worker_is_volatile(&id) != Some(true) {
        return Err(EngineError::PolicyViolation(format!(
            "worker::disconnect can only disconnect volatile workers ({id})"
        )));
    }
    let worker = host.inspect_worker(&id)?;
    host.unregister_worker(&id, worker.owner_actor.as_str())?;
    Ok(json!({ "disconnected": true }))
}

fn trace_get(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = required_str(&invocation.payload, "traceId")?;
    let invocations = host
        .invocations()
        .into_iter()
        .filter(|record| record.trace_id.as_str() == trace_id)
        .map(|record| invocation_record_value(&record))
        .collect::<Vec<_>>();
    let catalog_changes = host
        .ledger_catalog_changes()?
        .into_iter()
        .filter(|change| change.id.contains(trace_id) || change.subject_id.as_str() == trace_id)
        .map(|change| catalog_change_value(&change))
        .collect::<Vec<_>>();
    let approvals = host
        .approval_records_for_trace(trace_id)?
        .into_iter()
        .map(|record| json!(record))
        .collect::<Vec<_>>();
    let streams = host
        .stream_records_for_trace(trace_id)?
        .into_iter()
        .map(|record| json!(record))
        .collect::<Vec<_>>();
    Ok(json!({
        "traceId": trace_id,
        "invocations": invocations,
        "catalogChanges": catalog_changes,
        "streams": streams,
        "approvals": approvals,
        "leases": host.resource_leases_for_trace(trace_id)?,
        "compensation": host.compensation_records_for_trace(trace_id)?,
    }))
}

fn trace_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let mut traces = std::collections::BTreeMap::<String, usize>::new();
    for record in host.invocations() {
        *traces.entry(record.trace_id.to_string()).or_insert(0) += 1;
    }
    let traces = traces
        .into_iter()
        .rev()
        .take(limit.min(500))
        .map(|(trace_id, invocation_count)| {
            json!({
                "traceId": trace_id,
                "invocationCount": invocation_count,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "traces": traces }))
}

fn span_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = required_str(&invocation.payload, "traceId")?;
    let spans = host
        .invocations()
        .into_iter()
        .filter(|record| record.trace_id.as_str() == trace_id)
        .map(|record| {
            json!({
                "spanId": record.invocation_id.as_str(),
                "parentSpanId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
                "functionId": record.function_id.as_str(),
                "workerId": record.worker_id.as_str(),
                "triggerId": record.trigger_id.as_ref().map(TriggerId::as_str),
                "succeeded": record.succeeded,
                "timestamp": record.timestamp.to_rfc3339(),
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "traceId": trace_id, "spans": spans }))
}

fn log_query(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = optional_string(invocation.payload.get("traceId"))?;
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let logs = host
        .invocations()
        .into_iter()
        .filter(|record| {
            trace_id
                .as_ref()
                .map(|trace_id| record.trace_id.as_str() == trace_id)
                .unwrap_or(true)
        })
        .take(limit.min(500))
        .map(|record| {
            json!({
                "timestamp": record.timestamp.to_rfc3339(),
                "traceId": record.trace_id.as_str(),
                "invocationId": record.invocation_id.as_str(),
                "functionId": record.function_id.as_str(),
                "level": if record.succeeded { "info" } else { "error" },
                "message": if record.succeeded { "engine invocation succeeded" } else { "engine invocation failed" },
                "error": record.error.as_ref().map(error_value),
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "logs": logs }))
}

fn metrics_snapshot(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    Ok(json!({
        "metrics": {
            "catalogRevision": host.catalog_revision().0,
            "workers": host.worker_count(),
            "functions": host.function_count(),
            "triggers": host.trigger_count(),
            "triggerTypes": host.trigger_type_count(),
            "invocations": host.invocation_count(),
            "catalogChanges": host.catalog_change_count(),
        }
    }))
}

fn actor_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        authority_grant_id: context.authority_grant_id.clone(),
        authority_scopes: context.authority_scopes.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
    }
}

fn is_visibility_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
) -> bool {
    match visibility {
        VisibilityScope::Internal => actor.actor_kind.is_admin_like(),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(
                actor.actor_kind,
                crate::engine::discovery::ActorKind::Client
            ) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(
                actor.actor_kind,
                crate::engine::discovery::ActorKind::Worker
            ) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, crate::engine::discovery::ActorKind::Agent)
                || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
    }
}

fn catalog_change_value(change: &CatalogChange) -> Value {
    json!({
        "id": change.id.as_str(),
        "beforeRevision": change.before.0,
        "afterRevision": change.after.0,
        "kind": change_kind_str(&change.kind),
        "subjectId": change.subject_id.as_str(),
        "subjectKind": change.subject_kind.as_str(),
        "class": change.class.as_str(),
        "visibility": change.visibility.as_str(),
        "sessionId": change.session_id.as_deref(),
        "workspaceId": change.workspace_id.as_deref(),
        "ownerWorker": change.owner_worker.as_ref().map(WorkerId::as_str),
        "timestamp": change.timestamp.to_rfc3339(),
    })
}

fn invocation_record_value(record: &InvocationRecord) -> Value {
    json!({
        "invocationId": record.invocation_id.as_str(),
        "functionId": record.function_id.as_str(),
        "workerId": record.worker_id.as_str(),
        "functionRevision": record.function_revision.0,
        "catalogRevision": record.catalog_revision.0,
        "actorId": record.actor_id.as_str(),
        "actorKind": &record.actor_kind,
        "authorityGrantId": record.authority_grant_id.as_str(),
        "authorityScopes": &record.authority_scopes,
        "traceId": record.trace_id.as_str(),
        "parentInvocationId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
        "triggerId": record.trigger_id.as_ref().map(TriggerId::as_str),
        "deliveryMode": record.delivery_mode.as_str(),
        "idempotencyKey": record.idempotency_key.as_deref(),
        "idempotencyScope": record.idempotency_scope.as_ref().map(|scope| {
            json!({"kind": scope.kind.as_str(), "value": scope.value.as_str()})
        }),
        "resourceLeaseIds": &record.resource_lease_ids,
        "compensationStatus": record.compensation_status.as_deref(),
        "replayedFrom": record.replayed_from.as_ref().map(InvocationId::as_str),
        "succeeded": record.succeeded,
        "result": record.result_value.as_ref(),
        "error": record.error.as_ref().map(error_value),
        "timestamp": record.timestamp.to_rfc3339(),
    })
}

fn error_value(error: &EngineError) -> Value {
    json!({
        "message": error.to_string(),
        "kind": format!("{error:?}"),
    })
}

fn change_kind_str(kind: &crate::engine::types::CatalogChangeKind) -> &'static str {
    match kind {
        crate::engine::types::CatalogChangeKind::WorkerRegistered => "worker_registered",
        crate::engine::types::CatalogChangeKind::WorkerUpdated => "worker_updated",
        crate::engine::types::CatalogChangeKind::WorkerUnregistered => "worker_unregistered",
        crate::engine::types::CatalogChangeKind::FunctionRegistered => "function_registered",
        crate::engine::types::CatalogChangeKind::FunctionUpdated => "function_updated",
        crate::engine::types::CatalogChangeKind::FunctionUnregistered => "function_unregistered",
        crate::engine::types::CatalogChangeKind::TriggerTypeRegistered => "trigger_type_registered",
        crate::engine::types::CatalogChangeKind::TriggerTypeUpdated => "trigger_type_updated",
        crate::engine::types::CatalogChangeKind::TriggerTypeUnregistered => {
            "trigger_type_unregistered"
        }
        crate::engine::types::CatalogChangeKind::TriggerRegistered => "trigger_registered",
        crate::engine::types::CatalogChangeKind::TriggerUpdated => "trigger_updated",
        crate::engine::types::CatalogChangeKind::TriggerUnregistered => "trigger_unregistered",
        crate::engine::types::CatalogChangeKind::VisibilityChanged => "visibility_changed",
        crate::engine::types::CatalogChangeKind::HealthChanged => "health_changed",
    }
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected string, got {other}"
        ))),
    }
}

fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .map(Some)
            .ok_or_else(|| EngineError::PolicyViolation("expected unsigned integer".to_owned())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected integer, got {other}"
        ))),
    }
}

fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
    optional_string(value)?
        .map(|value| match value.as_str() {
            "internal" => Ok(VisibilityScope::Internal),
            "session" => Ok(VisibilityScope::Session),
            "workspace" => Ok(VisibilityScope::Workspace),
            "system" => Ok(VisibilityScope::System),
            "client" => Ok(VisibilityScope::Client),
            "worker" => Ok(VisibilityScope::Worker),
            "agent" => Ok(VisibilityScope::Agent),
            "admin" => Ok(VisibilityScope::Admin),
            other => Err(EngineError::PolicyViolation(format!(
                "unknown visibility {other}"
            ))),
        })
        .transpose()
}

fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value.to_owned())
}
