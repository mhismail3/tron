//! Long-running services that make engine primitives part of server runtime.
//!
//! JSON-RPC and WebSocket remain transports: queue draining and stream fan-out
//! live here so the engine's durable queue/stream primitives, not handlers, are
//! the source of truth for delayed work and push delivery.
//! The `agent` queue drains hidden prompt apply/drain functions so `agent.prompt`
//! can remain wire-compatible while startup and queued follow-up prompts run
//! through canonical engine functions.

use std::sync::Arc;
use std::time::Duration;

use crate::engine::{EngineHostHandle, EngineQueueDrainer, StreamActorScope, StreamCursor};
use crate::server::rpc::types::RpcEvent;
use crate::server::server::TronServer;
use crate::server::shutdown::ShutdownCoordinator;
use crate::server::websocket::broadcast::BroadcastManager;
use chrono::SecondsFormat;
use serde_json::Value;
use tokio_util::sync::CancellationToken;

const QUEUE_DRAIN_INTERVAL: Duration = Duration::from_millis(100);
const STREAM_PUMP_INTERVAL: Duration = Duration::from_millis(250);
const STREAM_PUMP_LIMIT: usize = 100;

/// Runtime-owned engine services.
pub struct EngineRuntimeServices;

impl EngineRuntimeServices {
    /// Start engine services and register them with server shutdown.
    pub fn start(server: &TronServer) {
        let host = server.rpc_context().engine_host.clone();
        let shutdown = server.shutdown().clone();
        for queue in ["default", "jobs", "agent"] {
            let service = EngineQueueDrainerService::new(
                host.clone(),
                queue.to_owned(),
                "tron-server".to_owned(),
                shutdown.token(),
            );
            shutdown.register_task(tokio::spawn(service.run()));
        }

        let pump = EngineStreamPump::new(
            host,
            server.broadcast().clone(),
            shutdown.clone(),
            [
                "approvals",
                "jobs",
                "agent.queue",
                "events.session",
                "catalog",
            ]
            .into_iter()
            .map(ToOwned::to_owned)
            .collect(),
        );
        shutdown.register_task(tokio::spawn(pump.run()));
    }
}

struct EngineQueueDrainerService {
    host: EngineHostHandle,
    queue: String,
    lease_owner: String,
    cancel: CancellationToken,
}

impl EngineQueueDrainerService {
    fn new(
        host: EngineHostHandle,
        queue: String,
        lease_owner: String,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            host,
            queue,
            lease_owner,
            cancel,
        }
    }

    async fn run(self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                () = async {
                    match EngineQueueDrainer::drain_once(&self.host, &self.queue, &self.lease_owner).await {
                        Ok(Some(result)) => {
                            if let Some(error) = result.error {
                                tracing::warn!(queue = %self.queue, error = %error, "engine queue item failed");
                            }
                        }
                        Ok(None) => tokio::time::sleep(QUEUE_DRAIN_INTERVAL).await,
                        Err(error) => {
                            tracing::warn!(queue = %self.queue, error = %error, "engine queue drainer failed");
                            tokio::time::sleep(QUEUE_DRAIN_INTERVAL).await;
                        }
                    }
                } => {}
            }
        }
    }
}

struct EngineStreamPump {
    host: EngineHostHandle,
    broadcast: Arc<BroadcastManager>,
    shutdown: Arc<ShutdownCoordinator>,
    topics: Vec<String>,
}

impl EngineStreamPump {
    fn new(
        host: EngineHostHandle,
        broadcast: Arc<BroadcastManager>,
        shutdown: Arc<ShutdownCoordinator>,
        topics: Vec<String>,
    ) -> Self {
        Self {
            host,
            broadcast,
            shutdown,
            topics,
        }
    }

    async fn run(self) {
        let mut cursors = self
            .topics
            .iter()
            .map(|topic| (topic.clone(), StreamCursor(0)))
            .collect::<std::collections::BTreeMap<_, _>>();
        for topic in &self.topics {
            let _ = self
                .host
                .subscribe_stream(
                    stream_pump_subscription_id(topic),
                    topic.clone(),
                    StreamCursor(0),
                    crate::engine::VisibilityScope::System,
                    None,
                    None,
                )
                .await;
        }
        let cancel = self.shutdown.token();

        loop {
            tokio::select! {
                () = cancel.cancelled() => break,
                () = tokio::time::sleep(STREAM_PUMP_INTERVAL) => {
                    for topic in &self.topics {
                        let cursor = cursors.get(topic).copied().unwrap_or(StreamCursor(0));
                        match self.host.poll_stream(
                            &stream_pump_subscription_id(topic),
                            Some(cursor),
                            STREAM_PUMP_LIMIT,
                            &StreamActorScope::admin(),
                        ).await {
                            Ok(page) => {
                                for event in &page.events {
                                    let rpc_event = stream_event_to_rpc_event(event);
                                    if let Some(session_id) = rpc_event.session_id.as_deref() {
                                        self.broadcast.broadcast_to_session(session_id, &rpc_event).await;
                                    } else {
                                        self.broadcast.broadcast_all(&rpc_event).await;
                                    }
                                }
                                let _ = cursors.insert(topic.clone(), page.next_cursor);
                            }
                            Err(error) => tracing::warn!(topic, error = %error, "engine stream pump poll failed"),
                        }
                    }
                }
            }
        }
    }
}

fn stream_pump_subscription_id(topic: &str) -> String {
    format!("server-stream-pump:{topic}")
}

fn stream_event_to_rpc_event(event: &crate::engine::EngineStreamEvent) -> RpcEvent {
    if let Some(wrapped) = event.payload.get("__rpcEvent")
        && let Ok(rpc_event) = serde_json::from_value::<RpcEvent>(wrapped.clone())
    {
        return rpc_event;
    }
    let event_type = event
        .payload
        .get("type")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("engine.{}", event.topic.replace('.', "_")));
    RpcEvent {
        event_type,
        session_id: event.session_id.clone(),
        timestamp: event
            .created_at
            .to_rfc3339_opts(SecondsFormat::Millis, true),
        data: Some(event.payload.clone()),
        run_id: None,
        sequence: None,
    }
}
