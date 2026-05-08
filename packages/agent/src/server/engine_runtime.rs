//! Long-running services that make engine primitives part of server runtime.
//!
//! JSON-RPC and WebSocket remain transports: queue draining and stream fan-out
//! live here so the engine's durable queue/stream primitives, not handlers, are
//! the source of truth for delayed work and push delivery.
//! The `agent` queue drains hidden prompt apply/drain functions so startup and
//! queued follow-up prompts run through canonical engine functions. The stream pump now owns the migrated
//! broadcast topics for approvals, auth/settings/MCP/device/cron/update/memory
//! status, jobs, agent queue, session events, sandbox/display lifecycle, and
//! catalog changes. The heartbeat service unregisters stale volatile local
//! external-worker capabilities so the live catalog reflects what can actually
//! run.

use std::sync::Arc;
use std::time::Duration;

use crate::engine::{EngineHostHandle, EngineQueueDrainer, StreamActorScope, StreamCursor};
use crate::server::server::TronServer;
use crate::server::services::events_wire::ServerEventPayload;
use crate::server::shutdown::ShutdownCoordinator;
use crate::server::transport::json_rpc::types::JsonRpcEvent;
use crate::server::websocket::broadcast::BroadcastManager;
use chrono::SecondsFormat;
use serde_json::Value;
use tokio_util::sync::CancellationToken;

const QUEUE_DRAIN_INTERVAL: Duration = Duration::from_millis(100);
const STREAM_PUMP_INTERVAL: Duration = Duration::from_millis(250);
const STREAM_PUMP_LIMIT: usize = 100;
const EXTERNAL_WORKER_HEARTBEAT_SCAN_INTERVAL: Duration = Duration::from_secs(10);
const EXTERNAL_WORKER_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(90);

/// Runtime-owned engine services.
pub struct EngineRuntimeServices;

impl EngineRuntimeServices {
    /// Start engine services and register them with server shutdown.
    pub fn start(server: &TronServer) {
        let host = server.capability_context().engine_host.clone();
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
                "auth",
                "settings",
                "mcp",
                "device",
                "cron",
                "updates",
                "memory",
                "display",
                "sandbox",
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

        let heartbeat = ExternalWorkerHeartbeatService::new(
            server.external_workers().clone(),
            shutdown.token(),
            EXTERNAL_WORKER_HEARTBEAT_TIMEOUT,
        );
        shutdown.register_task(tokio::spawn(heartbeat.run()));
    }
}

struct EngineQueueDrainerService {
    host: EngineHostHandle,
    queue: String,
    lease_owner: String,
    cancel: CancellationToken,
}

struct ExternalWorkerHeartbeatService {
    runtime: crate::server::external_workers::SharedExternalWorkerRuntime,
    cancel: CancellationToken,
    timeout: Duration,
}

impl ExternalWorkerHeartbeatService {
    fn new(
        runtime: crate::server::external_workers::SharedExternalWorkerRuntime,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> Self {
        Self {
            runtime,
            cancel,
            timeout,
        }
    }

    async fn run(self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                () = tokio::time::sleep(EXTERNAL_WORKER_HEARTBEAT_SCAN_INTERVAL) => {
                    let result = self
                        .runtime
                        .lock()
                        .await
                        .disconnect_timed_out(self.timeout)
                        .await;
                    match result {
                        Ok(expired) if !expired.is_empty() => {
                            tracing::warn!(count = expired.len(), "external engine workers timed out");
                        }
                        Ok(_) => {}
                        Err(error) => tracing::warn!(error = %error, "external worker heartbeat cleanup failed"),
                    }
                }
            }
        }
    }
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
                                    let (rpc_event, target) = stream_event_to_rpc_event(event);
                                    match target {
                                        StreamBroadcastTarget::All => {
                                            self.broadcast.broadcast_all(&rpc_event).await;
                                        }
                                        StreamBroadcastTarget::Session(session_id) => {
                                            self.broadcast.broadcast_to_session(&session_id, &rpc_event).await;
                                        }
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

enum StreamBroadcastTarget {
    All,
    Session(String),
}

fn stream_event_to_rpc_event(
    event: &crate::engine::EngineStreamEvent,
) -> (JsonRpcEvent, StreamBroadcastTarget) {
    if let Some(wrapped) = event.payload.get("serverEvent")
        && let Ok(mut server_event) = serde_json::from_value::<ServerEventPayload>(wrapped.clone())
    {
        server_event.stream_cursor = Some(event.cursor.0);
        if server_event.trace_id.is_none() {
            server_event.trace_id = event.trace_id.as_ref().map(ToString::to_string);
        }
        if server_event.parent_invocation_id.is_none() {
            server_event.parent_invocation_id =
                event.parent_invocation_id.as_ref().map(ToString::to_string);
        }
        let rpc_event = server_event.to_json_rpc_event();
        let target = stream_broadcast_target(event, &rpc_event);
        return (rpc_event, target);
    }
    let event_type = event
        .payload
        .get("type")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("engine.{}", event.topic.replace('.', "_")));
    let rpc_event = JsonRpcEvent {
        event_type,
        session_id: event.session_id.clone(),
        timestamp: event
            .created_at
            .to_rfc3339_opts(SecondsFormat::Millis, true),
        data: Some(event.payload.clone()),
        run_id: None,
        sequence: None,
    };
    let target = stream_broadcast_target(event, &rpc_event);
    (rpc_event, target)
}

fn stream_broadcast_target(
    event: &crate::engine::EngineStreamEvent,
    rpc_event: &JsonRpcEvent,
) -> StreamBroadcastTarget {
    if let Some(scope) = event.payload.get("__broadcastScope") {
        if scope.get("kind").and_then(Value::as_str) == Some("all") {
            return StreamBroadcastTarget::All;
        }
        if scope.get("kind").and_then(Value::as_str) == Some("session")
            && let Some(session_id) = scope.get("sessionId").and_then(Value::as_str)
        {
            return StreamBroadcastTarget::Session(session_id.to_owned());
        }
    }
    rpc_event
        .session_id
        .clone()
        .map(StreamBroadcastTarget::Session)
        .unwrap_or(StreamBroadcastTarget::All)
}
