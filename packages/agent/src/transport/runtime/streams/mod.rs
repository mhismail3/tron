//! Engine stream event pump — projects `TronEvent`s into neutral server events and
//! routes them through engine stream delivery.
//!
//! Runtime event classes publish to the engine stream primitive
//! (`events.session`). `/engine` clients subscribe, poll, and ack those stream
//! records directly; there is no separate broadcast transport.
//! Event projection is split by source family under `session/` so the pump stays
//! a runtime primitive: it owns delivery policy and stream records, while domain
//! folders own tool behavior.
//! Engine trace context carried by the source `TronEvent` is copied into both
//! the persisted engine stream row and the neutral payload so observability can
//! follow an agent turn through streamed UI events, tool invocation, queues, and
//! downstream tools.
//! If the bounded runtime receiver ever lags, the missing records cannot be
//! inferred from sequence gaps because durable-only events legitimately consume
//! sequences. The pump therefore publishes a system-scoped
//! `stream.recovery_required` control record directly to the engine stream. A
//! scoped client receives that record even through its session filter and must
//! reconstruct before trusting later live events. If the recovery record itself
//! cannot be stored, the pump stops instead of continuing with an undisclosed
//! continuity break.

use crate::engine::{
    EngineHostHandle, InvocationId, PublishStreamEvent, StreamVisibility, TraceId,
};
use crate::shared::protocol::events::TronEvent;
use crate::shared::server::events::ServerEventPayload;
use serde_json::json;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use routed::StreamScope;
use tron::tron_event_to_projected;

mod message;
mod routed;
mod session;
mod streaming;
mod tool_call;
mod tron;
mod turn;

/// System-scoped control event emitted when the live source receiver skips
/// records. This module owns both detection and the recovery wire contract.
pub(crate) const STREAM_RECOVERY_REQUIRED_EVENT_TYPE: &str = "stream.recovery_required";

/// Projects orchestrator events into engine streams.
pub struct EngineStreamEventPump {
    rx: broadcast::Receiver<TronEvent>,
    cancel: CancellationToken,
    engine_streams: EngineHostHandle,
}

impl EngineStreamEventPump {
    /// Create a new stream event pump.
    pub fn new(
        rx: broadcast::Receiver<TronEvent>,
        engine_streams: EngineHostHandle,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            rx,
            cancel,
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
                tracing::warn!(
                    lagged = n,
                    "stream projection lagged; requiring client recovery"
                );
                metrics::counter!("stream_projection_lagged_events_total", "source" => "engine_stream_event_pump")
                    .increment(n);
                self.publish_recovery_required(n).await
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::debug!("stream projection: sender closed, exiting");
                false
            }
        }
    }

    /// Publish the recovery marker outside the lagged broadcast path. Returning
    /// `false` stops the pump when even the durable control record cannot be
    /// stored; silently projecting later events would make the stream look
    /// continuous when it is not.
    async fn publish_recovery_required(&self, dropped_event_count: u64) -> bool {
        let server_event = ServerEventPayload::new(
            STREAM_RECOVERY_REQUIRED_EVENT_TYPE,
            None,
            Some(json!({
                "reason": "source_lag",
                "droppedEventCount": dropped_event_count,
            })),
        );
        let result = self
            .engine_streams
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": server_event,
                    "streamScope": { "kind": "all" },
                    "sourceEventType": STREAM_RECOVERY_REQUIRED_EVENT_TYPE,
                    "sourceSequence": null,
                }),
                visibility: StreamVisibility::System,
                session_id: None,
                workspace_id: None,
                producer: "agent-runtime".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await;

        match result {
            Ok(_) => true,
            Err(error) => {
                tracing::error!(
                    dropped_event_count,
                    error = %error,
                    "stream recovery marker publish failed; stopping runtime projection"
                );
                false
            }
        }
    }

    async fn project_tron_event(&self, event: &TronEvent) {
        let event_type = event.event_type();
        tracing::debug!(event_type, "projecting event to engine stream");
        let projected = tron_event_to_projected(event);
        let (visibility, session_id) = match &projected.scope {
            StreamScope::All => (StreamVisibility::System, None),
            StreamScope::Session(session_id) => {
                (StreamVisibility::Session, Some(session_id.clone()))
            }
        };
        let trace_id = event
            .trace_id()
            .and_then(|id| TraceId::new(id.to_owned()).ok());
        let parent_invocation_id = event
            .parent_invocation_id()
            .and_then(|id| InvocationId::new(id.to_owned()).ok());

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
                trace_id,
                parent_invocation_id,
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
