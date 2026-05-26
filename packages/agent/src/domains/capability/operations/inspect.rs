//! Capability inspection and status operations.

use serde_json::{Value, json};

use super::{
    actor_from_invocation, capability_result_value, record_admin_audit,
    registry_snapshot_from_store, registry_store_error, render_inspection_summary, resolve_target,
    sync_registry_for_admin,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{bool_field, parse_target};
use crate::engine::{ActorContext, Invocation};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

pub(crate) async fn inspect_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    if let Some(targets) = inspect_targets(&invocation.payload)? {
        let mut inspections = Vec::new();
        let mut summaries = Vec::new();
        for target_payload in targets {
            let inspection = inspect_one(&target_payload, deps, &actor, &trace_id).await?;
            summaries.push(render_inspection_summary(&inspection));
            inspections.push(inspection);
        }
        return capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
                "Inspected {} capability target(s): {}",
                inspections.len(),
                summaries.join("; ")
            ))]),
            details: Some(json!({ "inspections": inspections })),
            is_error: None,
            stop_turn: None,
        });
    }
    let details = inspect_one(&invocation.payload, deps, &actor, &trace_id).await?;
    let summary = render_inspection_summary(&details);
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(summary)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

async fn inspect_one(
    params: &Value,
    deps: &Deps,
    actor: &ActorContext,
    trace_id: &str,
) -> Result<Value, CapabilityError> {
    let target = resolve_target(params, deps, actor).await?;
    let inspection = target.entry.inspection(target.binding_decision.clone());
    {
        let store = deps.registry_store.clone();
        let entry = target.entry.clone();
        let decision = target.binding_decision.clone();
        let handle = inspection.inspection_handle.clone();
        let trace_id = trace_id.to_owned();
        run_blocking_task("capability.inspect.record", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_inspection(&handle, &entry, &decision)
                .map_err(registry_store_error)?;
            store
                .record_audit_event(
                    "capability.inspect",
                    Some(&trace_id),
                    json!({
                        "contractId": decision.contract_id,
                        "implementationId": decision.selected_implementation,
                        "functionId": decision.selected_function_id,
                        "catalogRevision": decision.catalog_revision,
                        "schemaDigest": decision.schema_digest,
                        "inspectionHandle": handle.handle,
                    }),
                )
                .map_err(registry_store_error)?;
            Ok(())
        })
        .await?;
    }
    serde_json::to_value(inspection).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

pub(super) fn inspect_targets(params: &Value) -> Result<Option<Vec<Value>>, CapabilityError> {
    let Some(values) = params.get("targets").and_then(Value::as_array) else {
        return Ok(None);
    };
    if values.is_empty() {
        return Ok(None);
    }
    let mut targets = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for value in values.iter().take(8) {
        let target = if let Some(id) = value.as_str() {
            json!({ "capabilityId": id })
        } else if value.is_object() {
            value.clone()
        } else {
            return Err(CapabilityError::InvalidParams {
                message: "capability inspect targets must be objects or capability id strings"
                    .to_owned(),
            });
        };
        if parse_target(&target).is_none() {
            return Err(CapabilityError::InvalidParams {
                message: "Each capability inspect target must include one of functionId, implementationId, capabilityId, or contractId".to_owned(),
            });
        }
        let key = serde_json::to_string(&target).map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
        if seen.insert(key) {
            targets.push(target);
        }
    }
    Ok(Some(targets))
}

pub(crate) async fn status_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let include_snapshot = bool_field(&invocation.payload, "includeSnapshot").unwrap_or(false);
    let store = deps.registry_store.clone();
    let mut status = run_blocking_task("capability.status", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.admin_status().map_err(registry_store_error)
    })
    .await?;
    status["serverProfile"] = json!({
        "profileName": deps.profile_runtime.current().profile_name(),
        "profileHash": deps.profile_runtime.current().spec_hash(),
    });
    if include_snapshot {
        let snapshot = registry_snapshot_from_store(deps).await?;
        status["snapshot"] = snapshot;
    }
    record_admin_audit(
        deps,
        invocation,
        "capability.status",
        json!({"includeSnapshot": include_snapshot}),
    )
    .await?;
    Ok(status)
}
