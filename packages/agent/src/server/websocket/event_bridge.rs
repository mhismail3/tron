//! Event bridge — converts `TronEvent`s from the Orchestrator broadcast into
//! `RpcEvent`s and routes them through WebSocket-compatible delivery.
//!
//! Migrated runtime event classes publish first to the engine stream primitive
//! (`events.session`) when an [`EngineHostHandle`] is attached. The stream pump
//! then rebroadcasts the wrapped `RpcEvent` shape. This keeps WebSocket as
//! delivery while making engine streams the live/resumable source for agent
//! runtime updates. Tests and unmigrated contexts may still construct a bridge
//! without engine streams and use direct broadcast.

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
use crate::server::rpc::types::RpcEvent;

#[cfg(test)]
fn tron_event_to_rpc(event: &TronEvent) -> RpcEvent {
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
    /// the wrapped [`RpcEvent`] shape. If publication fails, the bridge falls
    /// back to direct broadcast so existing clients do not lose live updates.
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

        if should_publish_stream_first(event)
            && let Some(host) = self.engine_streams.as_ref()
        {
            let published = host
                .publish_stream_event(PublishStreamEvent {
                    topic: "events.session".to_owned(),
                    payload: json!({
                        "__rpcEvent": bridged.rpc_event.clone(),
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
                .await;
            match published {
                Ok(_) => return,
                Err(error) => {
                    tracing::warn!(
                        event_type,
                        error = %error,
                        "engine stream publish failed; falling back to direct WebSocket broadcast"
                    );
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

#[cfg(test)]
#[path = "event_bridge/tests.rs"]
mod tests;
