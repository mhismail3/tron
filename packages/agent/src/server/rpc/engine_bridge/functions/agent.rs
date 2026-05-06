use super::*;

use crate::core::events::{BaseEvent, TronEvent};
use crate::server::rpc::prompt_queue::PromptQueueService;
use crate::server::rpc::validation;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "agent.queuePrompt" => queue_prompt_value(Some(payload), invocation, deps).await,
        "agent.dequeuePrompt" => dequeue_prompt_value(Some(payload), invocation, deps).await,
        "agent.clearQueue" => clear_queue_value(Some(payload), invocation, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("agent queue method {method} is not engine-owned"),
        }),
    }
}

async fn queue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let prompt_for_queue = prompt.clone();
    let item = run_blocking_task("agent.queuePrompt", move || {
        PromptQueueService::enqueue(&event_store, &sid, &prompt_for_queue)
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageQueued {
            base: BaseEvent::now(&session_id),
            queue_id: item.queue_id.clone(),
            text: item.text.clone(),
            position: item.position,
        });
    publish_agent_queue_stream(invocation, deps, &session_id, "queued", json!(&item)).await;

    serde_json::to_value(&item).map_err(|e| RpcError::Internal {
        message: format!("Failed to serialize queue item: {e}"),
    })
}

async fn dequeue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let queue_id = require_string_param(params, "queueId")?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let qid = queue_id.clone();
    run_blocking_task("agent.dequeuePrompt", move || {
        PromptQueueService::dequeue(&event_store, &sid, &qid, "cancelled")
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageDequeued {
            base: BaseEvent::now(&session_id),
            queue_id: queue_id.clone(),
            reason: "cancelled".into(),
        });
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "dequeued",
        json!({"queueId": queue_id, "reason": "cancelled"}),
    )
    .await;

    Ok(json!({ "ok": true }))
}

async fn clear_queue_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();

    let pending = run_blocking_task("agent.clearQueue.query", {
        let es = event_store.clone();
        let s = sid.clone();
        move || PromptQueueService::get_pending_queue(&es, &s)
    })
    .await?;

    let cleared = run_blocking_task("agent.clearQueue", move || {
        PromptQueueService::clear_queue(&event_store, &sid)
    })
    .await?;

    for item in &pending {
        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageDequeued {
                base: BaseEvent::now(&session_id),
                queue_id: item.queue_id.clone(),
                reason: "cleared".into(),
            });
    }
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "cleared",
        json!({"cleared": cleared, "items": pending}),
    )
    .await;

    Ok(json!({ "cleared": cleared }))
}

async fn publish_agent_queue_stream(
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "agent.queue".to_owned(),
            payload: json!({
                "action": action,
                "sessionId": session_id,
                "payload": payload,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "agent::queue".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}
