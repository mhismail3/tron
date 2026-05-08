//! Job workflow operations.
use super::{
    ENGINE_INTERNAL_INVOKE_SCOPE, EngineQueueDrainer, EnqueueInvocation, FunctionId,
    publish_queue_lifecycle_event,
};
use super::{persist_user_action, publish_job_stream};
use crate::engine::Invocation;
use crate::server::domains::job::Deps;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn enqueue_and_sync_drain_job_apply(
    function_id: &str,
    idempotency_prefix: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let function_id = FunctionId::new(function_id).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })?;
    let mut authority_scopes = invocation.causal_context.authority_scopes.clone();
    if !authority_scopes
        .iter()
        .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
    {
        authority_scopes.push(ENGINE_INTERNAL_INVOKE_SCOPE.to_owned());
    }
    let item = deps
        .engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: "jobs".to_owned(),
            function_id,
            target_revision: None,
            payload: invocation.payload.clone(),
            actor_id: invocation.causal_context.actor_id.clone(),
            actor_kind: invocation.causal_context.actor_kind.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            authority_scopes,
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
            trigger_id: invocation.causal_context.trigger_id.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            idempotency_key: Some(format!("{idempotency_prefix}:{}", invocation.id)),
        })
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    publish_queue_lifecycle_event(&deps.engine_host, "enqueue", &item, None).await;

    let drained = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        EngineQueueDrainer::drain_receipt(&deps.engine_host, &item.receipt_id, "engine-job-sync"),
    )
    .await
    .map_err(|_| CapabilityError::Internal {
        message: format!(
            "Timed out waiting for queued job command receipt {}",
            item.receipt_id
        ),
    })?
    .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    let Some(result) = drained else {
        return Err(CapabilityError::Internal {
            message: format!(
                "Queued job command receipt {} was not claimable",
                item.receipt_id
            ),
        });
    };
    crate::server::shared::error_mapping::result_to_capability_value(result)
}

pub(crate) async fn job_background_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    let pm = deps
        .process_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Process manager not available".into(),
        })?;
    pm.promote_to_background(&job_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("Failed to background: {e}"),
        })?;
    let label = pm
        .list_processes(&session_id)
        .into_iter()
        .find(|p| p.process_id == job_id)
        .map(|p| p.label)
        .unwrap_or_default();
    persist_user_action(
        &deps.event_store,
        &session_id,
        &job_id,
        "backgrounded",
        &label,
    );
    publish_job_stream(invocation, deps, &session_id, &job_id, "backgrounded").await;
    Ok(json!({
        "jobId": job_id,
        "backgrounded": true,
    }))
}

pub(crate) async fn job_cancel_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        jm.cancel_job(&job_id, true)
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else if let Some(ref pm) = deps.process_manager {
        pm.cancel_process(&job_id, true)
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else {
        return Err(CapabilityError::Internal {
            message: "No job manager available".into(),
        });
    }
    let label = deps
        .process_manager
        .as_ref()
        .map(|pm| {
            pm.list_processes(&session_id)
                .into_iter()
                .find(|p| p.process_id == job_id)
                .map(|p| p.label)
                .unwrap_or_default()
        })
        .unwrap_or_default();
    persist_user_action(&deps.event_store, &session_id, &job_id, "cancelled", &label);
    publish_job_stream(invocation, deps, &session_id, &job_id, "cancelled").await;
    Ok(json!({
        "jobId": job_id,
        "cancelled": true,
    }))
}
