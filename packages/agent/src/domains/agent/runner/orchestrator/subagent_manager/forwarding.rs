use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::shared::events::{BaseEvent, TronEvent};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

pub(super) fn spawn_child_event_forwarder(
    child_broadcast: &EventEmitter,
    forward_broadcast: Arc<EventEmitter>,
    child_session_id: String,
    parent_session_id: String,
) -> (CancellationToken, tokio::task::JoinHandle<()>) {
    let mut child_rx = child_broadcast.subscribe();
    let forward_cancel = CancellationToken::new();
    let forward_cancel_clone = forward_cancel.clone();

    let handle = tokio::spawn(async move {
        let mut current_turn: u32 = 0;
        loop {
            tokio::select! {
                event = child_rx.recv() => {
                    match event {
                        Ok(ref event) => {
                            if let TronEvent::TurnStart { turn, .. } = event {
                                current_turn = *turn;
                            }

                            if let Some(activity) = activity_text(event) {
                                let _ = forward_broadcast.emit(TronEvent::SubagentStatusUpdate {
                                    base: BaseEvent::now(&parent_session_id),
                                    subagent_session_id: child_session_id.clone(),
                                    status: "running".into(),
                                    current_turn,
                                    activity: Some(activity),
                                });
                            }

                            if let Some(forwarded_event) = forwarded_subagent_event(event) {
                                let _ = forward_broadcast.emit(TronEvent::SubagentEvent {
                                    base: BaseEvent::now(&parent_session_id),
                                    subagent_session_id: child_session_id.clone(),
                                    event: forwarded_event,
                                });
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => {
                            metrics::counter!("broadcast_lagged_events_total", "source" => "subagent_forward")
                                .increment(count);
                        }
                    }
                }
                () = forward_cancel_clone.cancelled() => {
                    while let Ok(_event) = child_rx.try_recv() {}
                    break;
                }
            }
        }
    });

    (forward_cancel, handle)
}

fn activity_text(event: &TronEvent) -> Option<String> {
    match event {
        TronEvent::TurnStart { turn, .. } => Some(format!("Turn {turn} started")),
        TronEvent::CapabilityInvocationStarted {
            model_primitive_name,
            ..
        } => Some(format!("Executing {model_primitive_name}")),
        TronEvent::CapabilityInvocationCompleted {
            model_primitive_name,
            duration,
            ..
        } => Some(format!("{model_primitive_name} completed ({duration}ms)")),
        _ => None,
    }
}

fn forwarded_subagent_event(event: &TronEvent) -> Option<Value> {
    match event {
        TronEvent::MessageUpdate { content, .. } => Some(json!({
            "type": "agent.text_delta",
            "data": { "delta": content },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::CapabilityInvocationStarted {
            invocation_id,
            model_primitive_name,
            arguments,
            ..
        } => Some(json!({
            "type": "capability.invocation.started",
            "data": {
                "invocationId": invocation_id,
                "modelPrimitiveName": model_primitive_name,
                "arguments": arguments,
            },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::CapabilityInvocationCompleted {
            invocation_id,
            model_primitive_name,
            is_error,
            duration,
            result,
            ..
        } => {
            let result_text =
                result
                    .as_ref()
                    .map(|capability_result| match &capability_result.content {
                        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => {
                            text.clone()
                        }
                        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
                            blocks
                                .iter()
                                .filter_map(|block| {
                                    if let crate::shared::content::CapabilityResultContent::Text {
                                        text,
                                    } = block
                                    {
                                        Some(text.as_str())
                                    } else {
                                        None
                                    }
                                })
                                .collect::<Vec<_>>()
                                .join("")
                        }
                    });
            Some(json!({
                "type": "capability.invocation.completed",
                "data": {
                    "invocationId": invocation_id,
                    "modelPrimitiveName": model_primitive_name,
                    "isError": is_error.unwrap_or(false),
                    "content": result_text.unwrap_or_default(),
                    "duration": duration,
                },
                "timestamp": chrono::Utc::now().to_rfc3339(),
            }))
        }
        TronEvent::TurnStart { turn, .. } => Some(json!({
            "type": "turn_start",
            "data": { "turn": turn },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::TurnEnd { turn, .. } => Some(json!({
            "type": "turn_end",
            "data": { "turn": turn },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        _ => None,
    }
}
