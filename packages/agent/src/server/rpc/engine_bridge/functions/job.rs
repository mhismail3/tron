use super::*;

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
        "job.list" => job_list_value(Some(payload), deps),
        "job.subscribe" => job_subscribe_value(Some(payload), deps).await,
        "job.unsubscribe" => job_unsubscribe_value(Some(payload)),
        _ => Err(RpcError::Internal {
            message: format!("job method {method} is not engine-owned"),
        }),
    }
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
