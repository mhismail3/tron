//! Privileged primitive query runtime.
//!
//! Catalog, worker, storage, and generated-UI primitives need access
//! to host-owned catalog and ledger state. The response contracts live here so
//! `EngineHost` stays a coordinator rather than a primitive response bucket.

use serde_json::{Value, json};

use super::{catalog, storage, ui, worker};
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::WorkerId;
use crate::engine::invocation::{CausalContext, Invocation};
use crate::engine::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion, UpdateResource,
};
use crate::engine::types::{
    CatalogRevision, FunctionDefinition, TriggerDefinition, TriggerTypeDefinition, VisibilityScope,
    WorkerDefinition,
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
    fn inspect_resource(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>>;
    fn create_resource(&mut self, request: CreateResource) -> Result<EngineResource>;
    fn update_resource(&mut self, request: UpdateResource) -> Result<EngineResourceVersion>;
    fn storage_stats(&self) -> Result<crate::shared::storage::StorageStatsReport>;
    fn storage_checkpoint(&self) -> Result<crate::shared::storage::StorageCheckpointReport>;
    fn storage_export_snapshot(
        &self,
        snapshot_path: &str,
    ) -> Result<crate::shared::storage::StorageExportReport>;
    fn storage_retention_run(
        &self,
        dry_run: bool,
        verbose_retention_days: u64,
    ) -> Result<crate::shared::storage::StorageRetentionReport>;
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
        ui::CREATE_SURFACE_FUNCTION
        | ui::UPDATE_SURFACE_FUNCTION
        | ui::INSPECT_SURFACE_FUNCTION
        | ui::VALIDATE_SURFACE_FUNCTION
        | ui::EXPIRE_SURFACE_FUNCTION
        | ui::DISCARD_SURFACE_FUNCTION
        | ui::SUBMIT_ACTION_FUNCTION => ui::dispatch(host, invocation),
        storage::STATS_FUNCTION => storage_stats(host),
        storage::CHECKPOINT_FUNCTION => storage_checkpoint(host),
        storage::EXPORT_SNAPSHOT_FUNCTION => storage_export_snapshot(host, invocation),
        storage::RETENTION_RUN_FUNCTION => storage_retention_run(host, invocation),
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

fn storage_stats(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    Ok(json!({ "stats": host.storage_stats()? }))
}

fn storage_checkpoint(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    Ok(json!({ "checkpoint": host.storage_checkpoint()? }))
}

fn storage_export_snapshot(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let snapshot_path = required_str(&invocation.payload, "snapshotPath")?;
    Ok(json!({ "export": host.storage_export_snapshot(snapshot_path)? }))
}

fn storage_retention_run(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let dry_run = invocation
        .payload
        .get("dryRun")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let verbose_retention_days =
        optional_u64(invocation.payload.get("verboseRetentionDays"))?.unwrap_or(7);
    Ok(json!({
        "retention": host.storage_retention_run(dry_run, verbose_retention_days)?
    }))
}

pub(in crate::engine::primitives) fn actor_context(context: &CausalContext) -> ActorContext {
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

pub(in crate::engine::primitives) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(in crate::engine::primitives) fn optional_string(
    value: Option<&Value>,
) -> Result<Option<String>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected string, got {other}"
        ))),
    }
}

pub(in crate::engine::primitives) fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
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
