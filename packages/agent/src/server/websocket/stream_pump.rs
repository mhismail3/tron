//! Engine stream event pump — projects `TronEvent`s into neutral server events and
//! routes them through engine stream delivery.
//!
//! Migrated runtime event classes publish to the engine stream primitive
//! (`events.session`). The stream pump then rebroadcasts the transport-specific
//! `/ws` event shape from the neutral stream payload, keeping WebSocket as
//! delivery while engine streams remain the live/resumable source for runtime
//! updates.

use std::sync::Arc;

use crate::core::events::TronEvent;
use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::runtime::orchestrator::turn_accumulator::TurnAccumulatorMap;
use serde_json::json;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use super::broadcast::BroadcastManager;
use routed::BroadcastScope;
use tron::tron_event_to_projected;

#[path = "stream_pump/hook.rs"]
mod hook;
#[path = "stream_pump/message.rs"]
mod message;
#[path = "stream_pump/routed.rs"]
mod routed;
#[path = "stream_pump/session.rs"]
mod session;
#[path = "stream_pump/streaming.rs"]
mod streaming;
#[path = "stream_pump/tool.rs"]
mod tool;
#[path = "stream_pump/tron.rs"]
mod tron;
#[path = "stream_pump/turn.rs"]
mod turn;

#[cfg(test)]
use crate::server::transport::json_rpc::types::JsonRpcEvent;

#[cfg(test)]
fn tron_event_to_rpc(event: &TronEvent) -> JsonRpcEvent {
    tron::tron_event_to_rpc(event)
}

/// Projects orchestrator events into engine streams and WebSocket delivery.
pub struct EngineStreamEventPump {
    rx: broadcast::Receiver<TronEvent>,
    broadcast: Arc<BroadcastManager>,
    cancel: CancellationToken,
    accumulators: Arc<TurnAccumulatorMap>,
    engine_streams: Option<EngineHostHandle>,
}

impl EngineStreamEventPump {
    /// Create a new stream event pump.
    pub fn new(
        rx: broadcast::Receiver<TronEvent>,
        broadcast: Arc<BroadcastManager>,
        cancel: CancellationToken,
        accumulators: Arc<TurnAccumulatorMap>,
    ) -> Self {
        Self {
            rx,
            broadcast,
            cancel,
            accumulators,
            engine_streams: None,
        }
    }

    /// Route stream-first runtime events through the engine stream primitive.
    ///
    /// WebSocket remains the delivery transport: migrated event classes are
    /// published to `events.session`, and the server stream pump rebroadcasts
    /// the current `/ws` shape from the neutral event payload.
    #[must_use]
    pub fn with_engine_streams(mut self, host: EngineHostHandle) -> Self {
        self.engine_streams = Some(host);
        self
    }

    /// Run the stream pump loop. Exits on shutdown signal or when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "stream_pump")]
    pub async fn run(mut self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => {
                    tracing::debug!("stream pump: shutdown signal received");
                    break;
                }
                result = self.rx.recv() => {
                    if !self.handle_tron_recv(result).await {
                        break;
                    }
                }
            }
        }
    }

    /// Process a `TronEvent` recv result. Returns `false` when the channel is closed.
    async fn handle_tron_recv(
        &mut self,
        result: Result<TronEvent, broadcast::error::RecvError>,
    ) -> bool {
        match result {
            Ok(event) => {
                self.project_tron_event(&event).await;
                true
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::debug!(lagged = n, "stream pump lagged");
                metrics::counter!("broadcast_lagged_events_total", "source" => "stream_pump")
                    .increment(n);
                true
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::debug!("stream pump: sender closed, exiting");
                false
            }
        }
    }

    async fn project_tron_event(&self, event: &TronEvent) {
        self.accumulators.update_from_event(event);

        let event_type = event.event_type();
        tracing::debug!(event_type, "projecting event to client delivery");
        let projected = tron_event_to_projected(event);

        if should_publish_stream_first(event) {
            let Some(host) = self.engine_streams.as_ref() else {
                tracing::warn!(
                    event_type,
                    "engine stream host missing; dropping stream-owned event"
                );
                return;
            };
            match host
                .publish_stream_event(PublishStreamEvent {
                    topic: "events.session".to_owned(),
                    payload: json!({
                        "serverEvent": projected.server_event.clone(),
                        "__broadcastScope": broadcast_scope_payload(&projected.scope),
                        "sourceEventType": event.event_type(),
                        "sourceSequence": event.sequence(),
                    }),
                    visibility: VisibilityScope::Session,
                    session_id: Some(event.session_id().to_owned()),
                    workspace_id: None,
                    producer: "agent-runtime".to_owned(),
                    trace_id: None,
                    parent_invocation_id: None,
                })
                .await
            {
                Ok(_) => return,
                Err(error) => {
                    tracing::warn!(
                        event_type,
                        error = %error,
                        "engine stream publish failed; dropping stream-owned event"
                    );
                    return;
                }
            }
        }

        match projected.scope {
            BroadcastScope::All => {
                self.broadcast
                    .broadcast_all(&projected.server_event.to_json_rpc_event())
                    .await;
            }
            BroadcastScope::Session(session_id) => {
                self.broadcast
                    .broadcast_to_session(&session_id, &projected.server_event.to_json_rpc_event())
                    .await;
            }
        }
    }
}

fn should_publish_stream_first(event: &TronEvent) -> bool {
    matches!(
        event,
        TronEvent::AgentStart { .. }
            | TronEvent::AgentEnd { .. }
            | TronEvent::AgentReady { .. }
            | TronEvent::AgentInterrupted { .. }
            | TronEvent::TurnStart { .. }
            | TronEvent::TurnEnd { .. }
            | TronEvent::TurnFailed { .. }
            | TronEvent::ResponseComplete { .. }
            | TronEvent::MessageUpdate { .. }
            | TronEvent::ToolUseBatch { .. }
            | TronEvent::ToolExecutionStart { .. }
            | TronEvent::ToolExecutionUpdate { .. }
            | TronEvent::ToolExecutionProgress { .. }
            | TronEvent::ToolExecutionEnd { .. }
            | TronEvent::ToolCallArgumentDelta { .. }
            | TronEvent::ToolCallGenerating { .. }
            | TronEvent::Error { .. }
            | TronEvent::ApiRetry { .. }
            | TronEvent::ThinkingStart { .. }
            | TronEvent::ThinkingDelta { .. }
            | TronEvent::ThinkingEnd { .. }
            | TronEvent::SessionUpdated { .. }
            | TronEvent::JobBackgrounded { .. }
    )
}

fn broadcast_scope_payload(scope: &BroadcastScope) -> serde_json::Value {
    match scope {
        BroadcastScope::All => json!({ "kind": "all" }),
        BroadcastScope::Session(session_id) => {
            json!({ "kind": "session", "sessionId": session_id })
        }
    }
}

#[cfg(test)]
#[path = "stream_pump/tests.rs"]
mod tests;
