//! Engine stream event pump — projects `TronEvent`s into neutral server events and
//! routes them through engine stream delivery.
//!
//! Runtime event classes publish to the engine stream primitive
//! (`events.session`). `/engine` clients subscribe, poll, and ack those stream
//! records directly; there is no separate broadcast transport.
//! Event projection is split by source family under `session/` so the pump stays
//! a runtime primitive: it owns delivery policy and stream records, while domain
//! folders own capability behavior.

use std::sync::Arc;

use crate::core::events::TronEvent;
use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::runtime::orchestrator::turn_accumulator::TurnAccumulatorMap;
use serde_json::json;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use routed::StreamScope;
use tron::tron_event_to_projected;

mod hook;
mod message;
mod routed;
mod session;
mod streaming;
mod tool;
mod tron;
mod turn;

/// Projects orchestrator events into engine streams.
pub struct EngineStreamEventPump {
    rx: broadcast::Receiver<TronEvent>,
    cancel: CancellationToken,
    accumulators: Arc<TurnAccumulatorMap>,
    engine_streams: EngineHostHandle,
}

impl EngineStreamEventPump {
    /// Create a new stream event pump.
    pub fn new(
        rx: broadcast::Receiver<TronEvent>,
        engine_streams: EngineHostHandle,
        cancel: CancellationToken,
        accumulators: Arc<TurnAccumulatorMap>,
    ) -> Self {
        Self {
            rx,
            cancel,
            accumulators,
            engine_streams,
        }
    }

    /// Run the stream projection loop. Exits on shutdown signal or when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "engine_stream_event_pump")]
    pub async fn run(mut self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => {
                    tracing::debug!("stream projection: shutdown signal received");
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
                tracing::debug!(lagged = n, "stream projection lagged");
                metrics::counter!("stream_projection_lagged_events_total", "source" => "engine_stream_event_pump")
                    .increment(n);
                true
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::debug!("stream projection: sender closed, exiting");
                false
            }
        }
    }

    async fn project_tron_event(&self, event: &TronEvent) {
        self.accumulators.update_from_event(event);

        let event_type = event.event_type();
        tracing::debug!(event_type, "projecting event to engine stream");
        let projected = tron_event_to_projected(event);
        let (visibility, session_id) = match &projected.scope {
            StreamScope::All => (VisibilityScope::System, None),
            StreamScope::Session(session_id) => {
                (VisibilityScope::Session, Some(session_id.clone()))
            }
        };
        if let Err(error) = self
            .engine_streams
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": projected.server_event.clone(),
                    "streamScope": stream_scope_payload(&projected.scope),
                    "sourceEventType": event.event_type(),
                    "sourceSequence": event.sequence(),
                }),
                visibility,
                session_id,
                workspace_id: None,
                producer: "agent-runtime".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
        {
            tracing::warn!(
                event_type,
                error = %error,
                "engine stream publish failed; dropping runtime event"
            );
        }
    }
}

fn stream_scope_payload(scope: &StreamScope) -> serde_json::Value {
    match scope {
        StreamScope::All => json!({ "kind": "all" }),
        StreamScope::Session(session_id) => {
            json!({ "kind": "session", "sessionId": session_id })
        }
    }
}

#[cfg(test)]
mod tests;
