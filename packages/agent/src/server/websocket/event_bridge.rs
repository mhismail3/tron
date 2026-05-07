//! Event bridge — converts `TronEvent`s from the Orchestrator broadcast into
//! `JsonRpcEvent`s and routes them through WebSocket-compatible delivery.
//!
//! Migrated runtime event classes publish to the engine stream primitive
//! (`events.session`). The stream pump then rebroadcasts the wrapped
//! `JsonRpcEvent` shape, keeping WebSocket as delivery while engine streams
//! remain the live/resumable source for runtime updates.

use std::sync::Arc;

use crate::core::events::TronEvent;
use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::runtime::orchestrator::turn_accumulator::TurnAccumulatorMap;
use serde_json::json;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use super::broadcast::BroadcastManager;
use routed::BroadcastScope;
use tron::tron_event_to_bridged;

#[path = "event_bridge/hook.rs"]
mod hook;
#[path = "event_bridge/message.rs"]
mod message;
#[path = "event_bridge/routed.rs"]
mod routed;
#[path = "event_bridge/session.rs"]
mod session;
#[path = "event_bridge/streaming.rs"]
mod streaming;
#[path = "event_bridge/tool.rs"]
mod tool;
#[path = "event_bridge/tron.rs"]
mod tron;
#[path = "event_bridge/turn.rs"]
mod turn;

#[cfg(test)]
use crate::server::transport::json_rpc::types::JsonRpcEvent;

#[cfg(test)]
fn tron_event_to_rpc(event: &TronEvent) -> JsonRpcEvent {
    tron::tron_event_to_rpc(event)
}

/// Bridges orchestrator events to WebSocket clients.
pub struct EventBridge {
    rx: broadcast::Receiver<TronEvent>,
    broadcast: Arc<BroadcastManager>,
    cancel: CancellationToken,
    accumulators: Arc<TurnAccumulatorMap>,
    engine_streams: Option<EngineHostHandle>,
}

impl EventBridge {
    /// Create a new event bridge.
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
    /// the wrapped [`JsonRpcEvent`] shape.
    #[must_use]
    pub fn with_engine_streams(mut self, host: EngineHostHandle) -> Self {
        self.engine_streams = Some(host);
        self
    }

    /// Run the bridge loop. Exits on shutdown signal or when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "event_bridge")]
    pub async fn run(mut self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => {
                    tracing::debug!("event bridge: shutdown signal received");
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
                self.bridge_tron_event(&event).await;
                true
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::debug!(lagged = n, "event bridge lagged");
                metrics::counter!("broadcast_lagged_events_total", "source" => "event_bridge")
                    .increment(n);
                true
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::debug!("event bridge: sender closed, exiting");
                false
            }
        }
    }

    async fn bridge_tron_event(&self, event: &TronEvent) {
        self.accumulators.update_from_event(event);

        let event_type = event.event_type();
        tracing::debug!(event_type, "bridging event to client");
        let bridged = tron_event_to_bridged(event);

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
                        "__rpcEvent": bridged.rpc_event.clone(),
                        "__broadcastScope": broadcast_scope_payload(&bridged.scope),
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

        match bridged.scope {
            BroadcastScope::All => self.broadcast.broadcast_all(&bridged.rpc_event).await,
            BroadcastScope::Session(session_id) => {
                self.broadcast
                    .broadcast_to_session(&session_id, &bridged.rpc_event)
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
#[path = "event_bridge/tests.rs"]
mod tests;
