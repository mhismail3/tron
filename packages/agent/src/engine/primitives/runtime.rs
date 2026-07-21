//! Privileged primitive query runtime.
//!
//! Catalog and storage primitives need access
//! to host-owned catalog and ledger state. The response contracts live here so
//! `EngineHost` stays a coordinator rather than a primitive response bucket.

use serde_json::{Value, json};

use super::{catalog, storage};
use crate::engine::catalog::discovery::{ActorContext, FunctionQuery};
use crate::engine::invocation::model::{CausalContext, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::types::{FunctionDefinition, VisibilityScope, WorkerDefinition};

/// Narrow host interface required by host-dispatched primitive workers.
pub(in crate::engine) trait PrimitiveRuntimeHost {
    fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition>;
    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition>;
    fn inspect_catalog_item(&self, invocation: &Invocation) -> Result<Value>;
    fn watch_catalog_snapshot_base(&self, invocation: &Invocation) -> Result<Value>;
    fn storage_stats(&self) -> Result<crate::shared::storage::StorageStatsReport>;
    fn storage_checkpoint(&self) -> Result<crate::shared::storage::StorageCheckpointReport>;
    fn storage_export_snapshot(
        &self,
        snapshot_path: &str,
    ) -> Result<crate::shared::storage::StorageExportReport>;
    fn storage_retention_run(
        &self,
        dry_run: bool,
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
        "functions": host.discover_functions(&query),
        "workers": host.visible_workers(&actor),
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
        },
        "currentRevision": response.get("currentRevision").cloned().unwrap_or(Value::Null),
        "nextRevision": response.get("nextRevision").cloned().unwrap_or(Value::Null),
        "hasMore": response.get("hasMore").cloned().unwrap_or(Value::Bool(false)),
    }))
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
    Ok(json!({
        "retention": host.storage_retention_run(dry_run)?
    }))
}

pub(in crate::engine::primitives) fn actor_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
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
