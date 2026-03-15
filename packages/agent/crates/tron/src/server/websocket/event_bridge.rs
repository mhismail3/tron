//! Event bridge — converts `TronEvent`s from the Orchestrator broadcast into
//! `RpcEvent`s and routes them through the `BroadcastManager`.

use std::sync::Arc;

use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use crate::core::events::TronEvent;
use crate::runtime::orchestrator::turn_accumulator::TurnAccumulatorMap;
use crate::tools::cdp::types::BrowserEvent;

use super::broadcast::BroadcastManager;
use browser::browser_event_to_bridged;
use routed::BroadcastScope;
use tron::tron_event_to_bridged;

#[path = "event_bridge/browser.rs"]
mod browser;
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

/// Bridges orchestrator events and browser events to WebSocket clients.
pub struct EventBridge {
    rx: broadcast::Receiver<TronEvent>,
    browser_rx: Option<broadcast::Receiver<BrowserEvent>>,
    broadcast: Arc<BroadcastManager>,
    cancel: CancellationToken,
    accumulators: Arc<TurnAccumulatorMap>,
}

impl EventBridge {
    /// Create a new event bridge.
    ///
    /// `browser_rx` is optional — when `None`, browser frame delivery is disabled.
    pub fn new(
        rx: broadcast::Receiver<TronEvent>,
        broadcast: Arc<BroadcastManager>,
        browser_rx: Option<broadcast::Receiver<BrowserEvent>>,
        cancel: CancellationToken,
        accumulators: Arc<TurnAccumulatorMap>,
    ) -> Self {
        Self {
            rx,
            browser_rx,
            broadcast,
            cancel,
            accumulators,
        }
    }

    /// Run the bridge loop. Exits on shutdown signal or when the broadcast sender is dropped.
    #[tracing::instrument(skip_all, name = "event_bridge")]
    pub async fn run(mut self) {
        if let Some(mut browser_rx) = self.browser_rx.take() {
            // Dual-channel select: TronEvent + BrowserEvent + shutdown
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
                    result = browser_rx.recv() => {
                        match result {
                            Ok(event) => self.bridge_browser_event(&event).await,
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                tracing::debug!(lagged = n, "browser event bridge lagged");
                                metrics::counter!("broadcast_lagged_events_total", "source" => "browser_bridge").increment(n);
                            }
                            Err(broadcast::error::RecvError::Closed) => {
                                tracing::debug!("browser event channel closed, continuing with TronEvent only");
                                self.run_tron_only().await;
                                break;
                            }
                        }
                    }
                }
            }
        } else {
            self.run_tron_only().await;
        }
    }

    async fn run_tron_only(&mut self) {
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

        match bridged.scope {
            BroadcastScope::All => self.broadcast.broadcast_all(&bridged.rpc_event).await,
            BroadcastScope::Session(session_id) => {
                self.broadcast
                    .broadcast_to_session(&session_id, &bridged.rpc_event)
                    .await;
            }
        }
    }

    async fn bridge_browser_event(&self, event: &BrowserEvent) {
        let bridged = browser_event_to_bridged(event);
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

#[cfg(test)]
#[path = "event_bridge/tests.rs"]
mod tests;
