use super::*;

use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{EngineQueueDrainer, EnqueueInvocation, FunctionId};
use tokio_util::sync::CancellationToken;

static ACTIVE_SUBSCRIPTIONS: std::sync::LazyLock<dashmap::DashMap<String, CancellationToken>> =
    std::sync::LazyLock::new(dashmap::DashMap::new);

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "job.background" => {
            enqueue_and_sync_drain_job_apply(
                "job::background_apply",
                "job.background.apply",
                invocation,
                deps,
            )
            .await
        }
        "job.cancel" => {
            enqueue_and_sync_drain_job_apply(
                "job::cancel_apply",
                "job.cancel.apply",
                invocation,
                deps,
            )
            .await
        }
        "job.background.apply" => job_background_apply_value(Some(payload), invocation, deps).await,
        "job.cancel.apply" => job_cancel_apply_value(Some(payload), invocation, deps).await,
        "job.list" => job_list_value(Some(payload), deps),
        "job.subscribe" => job_subscribe_value(Some(payload), deps).await,
        "job.unsubscribe" => job_unsubscribe_value(Some(payload)),
        _ => Err(RpcError::Internal {
            message: format!("job method {method} is not engine-owned"),
        }),
    }
}

async fn enqueue_and_sync_drain_job_apply(
    function_id: &str,
    idempotency_prefix: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let function_id = FunctionId::new(function_id).map_err(|e| RpcError::Internal {
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
        .map_err(super::super::engine_error_to_rpc)?;
    publish_queue_lifecycle_event(&deps.engine_host, "enqueue", &item, None).await;

    let drained = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        EngineQueueDrainer::drain_receipt(&deps.engine_host, &item.receipt_id, "rpc-job-sync"),
    )
    .await
    .map_err(|_| RpcError::Internal {
        message: format!(
            "Timed out waiting for queued job command receipt {}",
            item.receipt_id
        ),
    })?
    .map_err(super::super::engine_error_to_rpc)?;
    let Some(result) = drained else {
        return Err(RpcError::Internal {
            message: format!(
                "Queued job command receipt {} was not claimable",
                item.receipt_id
            ),
        });
    };
    super::super::result_to_rpc(result)
}

async fn job_background_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    let pm = deps
        .process_manager
        .as_ref()
        .ok_or_else(|| RpcError::Internal {
            message: "Process manager not available".into(),
        })?;
    pm.promote_to_background(&job_id)
        .map_err(|e| RpcError::Internal {
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

async fn job_cancel_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        jm.cancel_job(&job_id, true)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else if let Some(ref pm) = deps.process_manager {
        pm.cancel_process(&job_id, true)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else {
        return Err(RpcError::Internal {
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

fn job_list_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        Ok(json!({ "jobs": jm.list_jobs(&session_id) }))
    } else if let Some(ref pm) = deps.process_manager {
        Ok(json!({ "jobs": pm.list_processes(&session_id) }))
    } else {
        Ok(json!({ "jobs": [] }))
    }
}

fn persist_user_action(
    event_store: &Arc<crate::events::EventStore>,
    session_id: &str,
    job_id: &str,
    action: &str,
    label: &str,
) {
    match event_store.append(&crate::events::AppendOptions {
        session_id,
        event_type: crate::events::EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
        sequence: None,
    }) {
        Ok(event) => tracing::info!(
            job_id,
            action,
            session_id,
            event_id = %event.id,
            "persisted user job action"
        ),
        Err(error) => tracing::error!(
            job_id,
            action,
            session_id,
            error = %error,
            "failed to persist user job action"
        ),
    }
}

async fn publish_job_stream(
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    session_id: &str,
    job_id: &str,
    action: &str,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "jobs".to_owned(),
            payload: json!({
                "sessionId": session_id,
                "jobId": job_id,
                "action": action,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "job".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}

async fn job_subscribe_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    let registry = deps
        .output_buffer_registry
        .as_ref()
        .ok_or_else(|| RpcError::Internal {
            message: "Output buffer registry not available".into(),
        })?;
    let (buffer, tool_call_id) = registry
        .get(&job_id)
        .ok_or_else(|| RpcError::InvalidParams {
            message: format!("No output buffer for job: {job_id}"),
        })?;

    if let Some((_, old_cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
        old_cancel.cancel();
    }
    let cancel = CancellationToken::new();
    let _ = ACTIVE_SUBSCRIPTIONS.insert(job_id.clone(), cancel.clone());
    let emitter = deps.orchestrator.broadcast().clone();
    let sub_job_id = job_id.clone();
    drop(tokio::spawn(async move {
        run_subscriber(buffer, &tool_call_id, &session_id, &emitter, cancel).await;
        let _ = ACTIVE_SUBSCRIPTIONS.remove(&sub_job_id);
    }));

    Ok(json!({
        "subscribed": true,
        "jobId": job_id,
    }))
}

fn job_unsubscribe_value(params: Option<&Value>) -> Result<Value, RpcError> {
    let job_id = require_string_param(params, "jobId")?;
    let cancelled = if let Some((_, cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
        cancel.cancel();
        true
    } else {
        false
    };
    Ok(json!({
        "jobId": job_id,
        "unsubscribed": cancelled,
    }))
}

async fn run_subscriber(
    buffer: Arc<crate::runtime::orchestrator::output_buffer::SharedOutputBuffer>,
    tool_call_id: &str,
    session_id: &str,
    emitter: &Arc<crate::runtime::agent::event_emitter::EventEmitter>,
    cancel: CancellationToken,
) {
    let mut offset = 0;
    loop {
        let notified = buffer.notifier().notified();
        let (chunks, new_offset) = buffer.read_from(offset);
        offset = new_offset;
        for chunk in chunks {
            let _ = emitter.emit(crate::core::events::TronEvent::ToolExecutionUpdate {
                base: crate::core::events::BaseEvent::now(session_id),
                tool_call_id: tool_call_id.to_owned(),
                update: chunk,
            });
        }
        if buffer.is_closed() {
            let (final_chunks, _) = buffer.read_from(offset);
            for chunk in final_chunks {
                let _ = emitter.emit(crate::core::events::TronEvent::ToolExecutionUpdate {
                    base: crate::core::events::BaseEvent::now(session_id),
                    tool_call_id: tool_call_id.to_owned(),
                    update: chunk,
                });
            }
            break;
        }
        tokio::select! {
            () = cancel.cancelled() => break,
            () = notified => {}
        }
    }
}
